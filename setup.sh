#!/usr/bin/env bash
# Set up (or repair) this ComfyUI project on the current machine. Safe to re-run.
#
#   ./setup.sh               detect hardware, build the venv, install the systemd user service
#   ./setup.sh --dry-run     only print what would be done
#   ./setup.sh --no-service  skip the systemd user service
#   ./setup.sh --recreate-venv
#   TORCH_INDEX=cu128 ./setup.sh   force a PyTorch build (cu126, cu128, cu130, rocm, mps, cpu)
#   PYTHON_VERSION=3.13 ./setup.sh  Python for the venv (default 3.12, what the workflows were tested with)
#
# The venv is built with uv on a uv-managed Python, independent of the system/Homebrew Python.
# uv, its Python builds and its cache all live inside this directory (.uv/, .cache/uv).
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$PROJECT_DIR/.venv"
PYTHON_VERSION="${PYTHON_VERSION:-3.12}"
UV="$PROJECT_DIR/.uv/bin/uv"
export UV_PYTHON_INSTALL_DIR="$PROJECT_DIR/.uv/python"
export UV_CACHE_DIR="$PROJECT_DIR/.cache/uv"
export UV_PYTHON_PREFERENCE=only-managed
DRY_RUN=0 SERVICE=1 RECREATE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --no-service) SERVICE=0 ;;
    --recreate-venv) RECREATE=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '\n== %s\n' "$*"; }
run() { echo "+ $*"; [[ $DRY_RUN == 1 ]] || "$@"; }
die() { echo "ERROR: $*" >&2; exit 1; }
ver_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]; }

say "Machine"
OS="$(uname -s)" ARCH="$(uname -m)"
command -v curl >/dev/null || die "curl not found"
echo "os=$OS arch=$ARCH venv python=$PYTHON_VERSION (uv-managed)"

GPU_NAME="" CC="" VRAM_MB=0 DRIVER_CUDA="" UNIFIED_MB=0
if [[ $OS == Darwin ]]; then
  # Apple Silicon: the GPU (MPS) shares all of system memory
  [[ $ARCH == arm64 ]] || die "Intel Macs are not supported (no MPS GPU backend)"
  GPU_NAME="$(sysctl -n machdep.cpu.brand_string)" UNIFIED_MB=$(( $(sysctl -n hw.memsize) / 1048576 ))
  echo "gpu=$GPU_NAME unified_memory_mb=$UNIFIED_MB"
elif command -v nvidia-smi >/dev/null && nvidia-smi >/dev/null 2>&1; then
  IFS=, read -r GPU_NAME CC VRAM_MB < <(nvidia-smi --query-gpu=name,compute_cap,memory.total --format=csv,noheader,nounits | head -1)
  GPU_NAME="$(echo "$GPU_NAME" | xargs)" CC="$(echo "$CC" | xargs)" VRAM_MB="$(echo "$VRAM_MB" | xargs)"
  [[ $VRAM_MB =~ ^[0-9]+$ ]] || VRAM_MB=0  # unified-memory GPUs (e.g. GB10) report N/A
  DRIVER_CUDA="$(nvidia-smi | grep -o 'CUDA Version: [0-9.]*' | awk '{print $3}')"
  echo "gpu=$GPU_NAME compute_capability=$CC vram_mb=$VRAM_MB driver_cuda=$DRIVER_CUDA"
else
  echo "no NVIDIA GPU detected"
fi

# AMD GPUs: read the gfx target from the amdgpu KFD topology (no ROCm install needed), e.g. 110003 -> gfx1103
GFX="" GTT_MB=0 IGPU=0
if [[ -z $GPU_NAME ]]; then
  for props in /sys/class/kfd/kfd/topology/nodes/*/properties; do
    [[ -r $props ]] || continue
    v="$(awk '$1 == "gfx_target_version" {print $2}' "$props")"
    [[ ${v:-0} -gt 0 ]] || continue
    GFX="$(printf 'gfx%d%d%x' $((v / 10000)) $((v / 100 % 100)) $((v % 100)))"
    [[ "$(awk '$1 == "local_mem_size" {print $2}' "$props")" == 0 ]] && IGPU=1  # integrated: no dedicated VRAM
    break
  done
  if [[ -n $GFX ]]; then
    for d in /sys/class/drm/card*/device; do
      [[ -r $d/mem_info_vram_total ]] || continue
      VRAM_MB=$(( $(cat "$d/mem_info_vram_total") / 1048576 )) GTT_MB=$(( $(cat "$d/mem_info_gtt_total") / 1048576 ))
      break
    done
    GPU_NAME="AMD $GFX"
    echo "gpu=$GPU_NAME vram_mb=$VRAM_MB gtt_mb=$GTT_MB"
    [[ -r /dev/kfd && -w /dev/kfd ]] || die "no access to /dev/kfd; add yourself to the render group"
  fi
fi

# PyTorch CUDA builds: cu126 still covers Maxwell/Pascal/Volta (CC < 7.5); cu128/cu130 need Turing (7.5) or newer,
# and Blackwell (CC >= 10) needs cu128+. The build's CUDA version must not exceed what the driver supports.
if [[ -z ${TORCH_INDEX:-} ]]; then
  if [[ $OS == Darwin ]]; then
    TORCH_INDEX=mps
  elif [[ -n $GFX ]]; then
    TORCH_INDEX=rocm
  elif [[ -z $CC ]]; then
    TORCH_INDEX=cpu
  elif ! ver_ge "$CC" 7.5; then
    ver_ge "$DRIVER_CUDA" 12.6 || die "GPU needs a driver supporting CUDA 12.6+ (has $DRIVER_CUDA)"
    TORCH_INDEX=cu126
  elif ver_ge "$DRIVER_CUDA" 13.0; then
    TORCH_INDEX=cu130
  elif ver_ge "$DRIVER_CUDA" 12.8; then
    TORCH_INDEX=cu128
  elif ver_ge "$DRIVER_CUDA" 12.6 && ! ver_ge "$CC" 10.0; then
    TORCH_INDEX=cu126
  else
    die "NVIDIA driver too old (CUDA $DRIVER_CUDA); update the driver"
  fi
fi
echo "pytorch build: $TORCH_INDEX"
[[ $TORCH_INDEX == cpu ]] && echo "WARNING: CPU-only PyTorch; image edits will be extremely slow"

say "ComfyUI source"
if [[ -f $PROJECT_DIR/ComfyUI/main.py ]]; then
  echo "present"
elif [[ -e $PROJECT_DIR/.git ]]; then  # fresh clone of this repo: ComfyUI is a submodule pinned to a tested commit
  run git -C "$PROJECT_DIR" submodule update --init ComfyUI
else
  run git clone --depth 1 https://github.com/Comfy-Org/ComfyUI.git "$PROJECT_DIR/ComfyUI"
fi

say "uv"
if [[ -x $UV ]]; then
  echo "present: $("$UV" --version)"
else
  run bash -c "curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR='$PROJECT_DIR/.uv/bin' UV_NO_MODIFY_PATH=1 sh"
fi

say "Python venv"
if [[ -x $VENV/bin/python ]] && [[ $RECREATE == 0 ]]; then
  read -r VENV_PYV VENV_BASE < <("$VENV/bin/python" -c 'import sys; print("%d.%d" % sys.version_info[:2], sys.base_prefix)' 2>/dev/null || echo broken -)
  if [[ $VENV_BASE != "$UV_PYTHON_INSTALL_DIR"/* ]]; then
    echo "existing venv is not on uv-managed Python ($VENV_BASE); recreating"
    RECREATE=1
  elif [[ $VENV_PYV != "$PYTHON_VERSION" ]]; then
    echo "existing venv is Python $VENV_PYV, want $PYTHON_VERSION; recreating"
    RECREATE=1
  else
    echo "keeping existing Python $VENV_PYV venv"
  fi
fi
if [[ $RECREATE == 1 ]] || [[ ! -x $VENV/bin/python ]]; then
  run rm -rf "$VENV"
  # --no-bin: don't add a python3.X command to ~/.local/bin; only this project uses it
  run "$UV" python install --no-bin "$PYTHON_VERSION"
  # --seed adds pip: ComfyUI-Manager runs `python -m pip` to install custom node dependencies
  run "$UV" venv --seed --python "$PYTHON_VERSION" "$VENV"
fi
CURRENT_TORCH="$("$VENV/bin/python" -c 'import torch, torchvision; print(torch.__version__)' 2>/dev/null || true)"
if [[ $CURRENT_TORCH == *"+$TORCH_INDEX"* ]] || [[ $TORCH_INDEX == mps && -n $CURRENT_TORCH && $CURRENT_TORCH != *+* ]]; then
  echo "torch $CURRENT_TORCH already installed"
elif [[ $TORCH_INDEX == mps ]]; then
  # the macOS wheels on PyPI include MPS; they carry no +local version tag
  run "$UV" pip install --python "$VENV" torch torchvision torchaudio
elif [[ $TORCH_INDEX == rocm ]]; then
  # AMD's multi-arch wheels: the device extra pulls the kernels and ROCm runtime for this GPU only
  [[ -n $GFX ]] || die "TORCH_INDEX=rocm needs an AMD GPU"
  # Pin a matched set: left alone, uv pairs the newest torch with a torchvision built for the previous one
  ROCM_TORCH="${ROCM_TORCH:-2.13.0+rocm10.1.0}" ROCM_TORCHVISION="${ROCM_TORCHVISION:-0.28.0+rocm10.1.0}"
  run "$UV" pip install --python "$VENV" --index-url https://stable.repo.amd.com/rocm/whl-next/ \
    "torch[device-$GFX]==$ROCM_TORCH" "torchvision[device-$GFX]==$ROCM_TORCHVISION" "torchaudio==2.11.0.3+${ROCM_TORCH#*+}"
else
  run "$UV" pip install --python "$VENV" torch torchvision torchaudio --index-url "https://download.pytorch.org/whl/$TORCH_INDEX"
fi
run "$UV" pip install --python "$VENV" -r "$PROJECT_DIR/ComfyUI/requirements.txt" -r "$PROJECT_DIR/ComfyUI/manager_requirements.txt"
if [[ $DRY_RUN == 0 ]] && [[ $TORCH_INDEX == mps ]]; then
  "$VENV/bin/python" -c 'import torch; assert torch.backends.mps.is_available(), "MPS not available"; x = torch.randn(256, 256, device="mps"); (x @ x).sum().item(); print("torch", torch.__version__, "OK on MPS")'
elif [[ $DRY_RUN == 0 ]] && [[ $TORCH_INDEX != cpu ]]; then
  "$VENV/bin/python" -c 'import torch; assert torch.cuda.is_available(), "CUDA not available"; x = torch.randn(256, 256, device="cuda"); (x @ x).sum().item(); print("torch", torch.__version__, "OK on", torch.cuda.get_device_name(0))'
fi

say "Project directories"
run mkdir -p "$PROJECT_DIR/.cache" "$PROJECT_DIR/.tmp" "$PROJECT_DIR/workflows" "$PROJECT_DIR/ComfyUI/user/default"
# Our custom nodes and workflows live at the project root (this repo); ComfyUI, an upstream checkout, sees them
# through symlinks. Whatever was at a link's place before (an older copy) is moved to .tmp/replaced-by-links/.
BACKUP="$PROJECT_DIR/.tmp/replaced-by-links/$(date +%Y%m%d-%H%M%S)"
link_into_comfyui() {  # DEST TARGET (relative to DEST's directory)
  if [[ -L $1 ]]; then
    [[ "$(readlink "$1")" == "$2" ]] && return 0
    run rm "$1"
  elif [[ -e $1 ]]; then
    run mkdir -p "$BACKUP"
    run mv "$1" "$BACKUP/"
    echo "  (moved the old $(basename "$1") to $BACKUP)"
  fi
  run ln -s "$2" "$1"
}
for pack in "$PROJECT_DIR"/custom_nodes/*/; do
  pack="$(basename "$pack")"
  link_into_comfyui "$PROJECT_DIR/ComfyUI/custom_nodes/$pack" "../../custom_nodes/$pack"
done
WF="$PROJECT_DIR/ComfyUI/user/default/workflows"
if [[ -d $WF ]] && [[ ! -L $WF ]]; then  # keep workflows that only exist on this machine
  for f in "$WF"/*.json; do
    [[ -e $f ]] && [[ ! -e "$PROJECT_DIR/workflows/$(basename "$f")" ]] && run cp -p "$f" "$PROJECT_DIR/workflows/"
  done
fi
link_into_comfyui "$WF" "../../../workflows"

if [[ $SERVICE == 1 ]] && [[ $OS == Darwin ]]; then
  say "Service"
  echo "macOS: no systemd user service; start ComfyUI with ./run.sh"
elif [[ $SERVICE == 1 ]]; then
  say "systemd user service"
  UNIT="$PROJECT_DIR/comfyui.service"
  if [[ $DRY_RUN == 0 ]]; then
    sed -i -e "s|^WorkingDirectory=.*|WorkingDirectory=$PROJECT_DIR|" -e "s|^ExecStart=.*|ExecStart=$PROJECT_DIR/run.sh|" "$UNIT"
  fi
  echo "unit: $UNIT ($(grep ^ExecStart= "$UNIT"))"
  LINK="$HOME/.config/systemd/user/comfyui.service"
  if [[ -L $LINK ]] && [[ "$(readlink -f "$LINK")" != "$UNIT" ]]; then
    echo "comfyui.service currently points at $(readlink "$LINK"); relinking"
    run systemctl --user disable comfyui.service
  fi
  run systemctl --user link "$UNIT"
  run systemctl --user daemon-reload
  run systemctl --user enable comfyui.service
  run systemctl --user restart comfyui.service
  if [[ $DRY_RUN == 0 ]]; then
    for _ in $(seq 1 60); do curl -s -o /dev/null http://127.0.0.1:8188/ && break; sleep 2; done
    curl -s -o /dev/null http://127.0.0.1:8188/ && echo "ComfyUI is up at http://127.0.0.1:8188" || echo "WARNING: not responding yet; check: journalctl --user -u comfyui -f"
  fi
fi

say "Next steps"
# Radeon 780M: with compute wave save/restore on, the MES firmware hangs the GPU (then resets it) when memory
# pressure makes the driver evict ComfyUI's queues, typically while models load
if [[ $GFX == gfx1103 ]] && [[ "$(cat /sys/module/amdgpu/parameters/cwsr_enable 2>/dev/null)" != 0 ]]; then
  echo "- WARNING: add amdgpu.cwsr_enable=0 to the kernel command line, or this GPU hangs while models load:"
  echo "    echo 'GRUB_CMDLINE_LINUX_DEFAULT=\"\${GRUB_CMDLINE_LINUX_DEFAULT} amdgpu.cwsr_enable=0\"' | sudo tee /etc/default/grub.d/61-amdgpu-cwsr.cfg"
  echo "    sudo update-grub, then reboot"
fi
if HF_HOME="$PROJECT_DIR/.cache/huggingface" "$VENV/bin/python" -c 'import sys; from huggingface_hub import get_token; sys.exit(0 if get_token() else 1)' 2>/dev/null; then
  echo "- Hugging Face: logged in"
else
  echo "- Log in to Hugging Face: ./hf.sh auth login"
fi
if [[ $UNIFIED_MB -gt 0 ]]; then
  if [[ $UNIFIED_MB -ge 45000 ]]; then
    echo "- ${UNIFIED_MB} MB unified memory: use the Turbo and 8GB workflows; int8 Qwen models should fit, bf16 ones will not"
  else
    echo "- ${UNIFIED_MB} MB unified memory: use the People Edit 8GB workflows"
  fi
  echo "- MPS has no fp8: in the 8GB workflows pick the bf16 models from Comfy-Org/Flux-2-Klein-4B instead"
  echo "  (flux-2-klein-4b.safetensors, qwen_3_4b.safetensors under split_files/)"
elif [[ $IGPU == 1 ]]; then
  echo "- iGPU shares system RAM (${VRAM_MB} MB carve-out + ${GTT_MB} MB GTT): use the Turbo and 8GB workflows"
elif [[ $VRAM_MB -gt 0 ]]; then
  if [[ $VRAM_MB -ge 23000 ]]; then
    echo "- ${VRAM_MB} MB VRAM: all People Edit workflows should run"
  elif [[ $VRAM_MB -ge 11000 ]]; then
    echo "- ${VRAM_MB} MB VRAM: use the Turbo and 8GB workflows (Qwen ones may need int8 models)"
  else
    echo "- ${VRAM_MB} MB VRAM: use the People Edit 8GB workflows"
  fi
fi
echo "- Missing models: open a workflow, then Extensions -> Download missing models to server"
[[ $OS == Darwin ]] || echo "- Optional, keep running without a login session: loginctl enable-linger"
