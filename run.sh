#!/usr/bin/env bash
# Launch ComfyUI bound to localhost only, with all state kept inside this project directory.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${COMFYUI_PORT:-8188}"

# Keep caches (HF, torch, triton, pip, etc.) inside the project instead of ~/.cache
export XDG_CACHE_HOME="$PROJECT_DIR/.cache"
export HF_HOME="$XDG_CACHE_HOME/huggingface"
export TORCH_HOME="$XDG_CACHE_HOME/torch"
export TRITON_CACHE_DIR="$XDG_CACHE_HOME/triton"
export PIP_CACHE_DIR="$XDG_CACHE_HOME/pip"
export TMPDIR="$PROJECT_DIR/.tmp"
mkdir -p "$XDG_CACHE_HOME" "$TMPDIR"
# AMD/ROCm: MIOpen keeps its tuned-kernel databases in ~/.config and ~/.cache by default
export MIOPEN_USER_DB_PATH="$XDG_CACHE_HOME/miopen"
export MIOPEN_CUSTOM_CACHE_DIR="$XDG_CACHE_HOME/miopen"
# Apple Silicon: run ops MPS lacks on the CPU instead of failing
export PYTORCH_ENABLE_MPS_FALLBACK=1
# Unsupported AMD GPUs can borrow a supported target's kernels, e.g. HSA_OVERRIDE_GFX_VERSION=11.0.0
# for gfx1103 (Radeon 780M), with pytorch.org ROCm wheels. AMD's per-device wheels that setup.sh installs ship
# only the detected GPU's kernels, so the override fails there with hipErrorInvalidKernelFile.

PYTHON="$PROJECT_DIR/.venv/bin/python"
# SageAttention is built locally (see .cache/build/SageAttention); ComfyUI refuses to start with the flag but no package
EXTRA_ARGS=()
if "$PYTHON" -c 'import importlib.util, sys; sys.exit(importlib.util.find_spec("sageattention") is None)'; then
  EXTRA_ARGS+=(--use-sage-attention)
fi
# Radeon 780M (gfx1103): ComfyUI defaults to sub-quadratic attention there; PyTorch attention is ~8% faster
# per edit. Not with --cpu, where PyTorch's bf16 attention is several times slower.
if grep -qx 'gfx_target_version 110003' /sys/class/kfd/kfd/topology/nodes/*/properties 2>/dev/null && [[ " $* " != *" --cpu "* ]]; then
  EXTRA_ARGS+=(--use-pytorch-cross-attention)
fi
# Apple Silicon: ComfyUI runs the text encoder on the CPU in fp16 there and uses sub-quadratic attention. With
# unified memory there is nothing to offload to; keeping everything on the GPU plus PyTorch attention is ~17%
# faster per edit (M5 Pro, People Edit 8GB with bf16 models). For Wan 2.2 14B video, which fills a 48 GB Mac,
# --gpu-only is ~12% slower; COMFYUI_GPU_ONLY=0 ./run.sh leaves it out.
if [[ "$(uname -s)" == Darwin ]] && [[ " $* " != *" --cpu "* ]]; then
  [[ "${COMFYUI_GPU_ONLY:-1}" == 1 ]] && EXTRA_ARGS+=(--gpu-only)
  EXTRA_ARGS+=(--use-pytorch-cross-attention)
fi

cd "$PROJECT_DIR/ComfyUI"
exec "$PYTHON" main.py \
  --listen 127.0.0.1 \
  --port "$PORT" \
  --base-directory "$PROJECT_DIR/ComfyUI" \
  --enable-assets \
  --database-url "sqlite:///$PROJECT_DIR/ComfyUI/user/comfyui.db" \
  ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} "$@"  # bash 3.2 (macOS) treats an empty "${arr[@]}" as unset
