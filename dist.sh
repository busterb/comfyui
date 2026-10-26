#!/usr/bin/env bash
# Package this project for another computer. Unpack there and run ./setup.sh.
#
#   ./dist.sh                 setup only: ComfyUI source, scripts, extension, workflows, settings (~25 MB)
#   ./dist.sh --with-models   also include ComfyUI/models (large; safetensors don't compress)
#   ./dist.sh --with-images   also include ComfyUI/input and ComfyUI/output
#   ./dist.sh -o FILE         output path (default: comfyui-setup-YYYYMMDD.tar.gz in this directory)
#
# Never included: .venv and .uv (machine-specific; setup.sh rebuilds them), .cache (holds the
# Hugging Face token; log in again with ./hf.sh auth login), .tmp, ComfyUI/temp, __pycache__, and the
# asset database (it only indexes local files; the new machine builds its own).
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="$(basename "$PROJECT_DIR")"
MODELS=0 IMAGES=0
OUT="$PROJECT_DIR/comfyui-setup-$(date +%Y%m%d).tar.gz"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-models) MODELS=1 ;;
    --with-images) IMAGES=1 ;;
    -o) OUT="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; shift ;;  # no GNU realpath -m on macOS
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

LIST="$(mktemp)"
trap 'rm -f "$LIST"' EXIT
cd "$(dirname "$PROJECT_DIR")"
C="$NAME/ComfyUI"

find "$NAME" -mindepth 1 \
  \( -path "$NAME/.venv" -o -path "$NAME/.uv" -o -path "$NAME/.cache" -o -path "$NAME/.tmp" \
     -o -path "$C/temp" -o -name __pycache__ -o -name '*.tar.gz' \) -prune -o \
  \( -type f -o -type l \) -print |
  grep -vE "^$C/user/comfyui(-client(-[0-9]+)?)?\.db" |
  { if [[ $MODELS == 1 ]]; then cat; else grep -vE "^$C/models/.*\.(safetensors|ckpt|pt|pth|bin|gguf|sft|onnx)$"; fi; } |
  { if [[ $IMAGES == 1 ]]; then cat; else grep -vE "^$C/(input|output)/" || true; fi; } > "$LIST"
if [[ $IMAGES == 0 ]]; then
  # keep the files that ship with ComfyUI itself
  for f in "$C/input/example.png" "$C/output/_output_images_will_be_put_here"; do
    [[ -e $f ]] && echo "$f" >> "$LIST"
  done
fi

if grep -qE "^$NAME/\.cache/|/token$|stored_tokens$" "$LIST"; then
  echo "refusing: credential files ended up in the file list" >&2
  exit 1
fi

if [[ $MODELS == 1 ]]; then
  tar -cf "${OUT%.gz}" --no-recursion -T "$LIST"  # model weights don't compress; skip gzip
  OUT="${OUT%.gz}"
else
  tar -czf "$OUT" --no-recursion -T "$LIST"
fi

echo "$OUT"
echo "$(wc -l < "$LIST") files, $(du -h "$OUT" | cut -f1)"
echo
echo "On the other computer:"
echo "  tar -xf $(basename "$OUT") -C ~/projects     # creates ~/projects/$NAME"
echo "  cd ~/projects/$NAME && ./setup.sh --dry-run && ./setup.sh"
echo "  ./hf.sh auth login"
[[ $MODELS == 1 ]] || echo "  then open a workflow and use Extensions -> Download missing models to server"
