#!/usr/bin/env bash
# Train a character LoRA for the People Edit Turbo model (Qwen Image 2.1) on a compute machine.
#
#   1. Put 15-30 photos of the character in ComfyUI/input/lora/NAME/: varied angles, poses, lighting and
#      backgrounds, the character alone in each.
#   2. ./lora.sh caption NAME HOST    draft a caption for each photo (NAME.txt next to it), with Qwen3-VL on HOST.
#                                     Read them and fix what's wrong: they should describe pose, framing, setting
#                                     and light, not the character's looks.
#   3. ./lora.sh train NAME HOST      train on HOST (1-2 hours on the GB10). The LoRA lands in
#                                     models/loras/characters/NAME.safetensors there and here.
#
# HOST is an SSH host running this project's ComfyUI (port 8188, or HOST:PORT), like remote.sh's.
# For a RunPod pod: SSH_CONFIG=.cache/runpod/ssh_config ./lora.sh train NAME runpod
# Options: --trigger WORD (the name in prompts, default NAME); train: --steps, --rank, --learning-rate;
# caption: --overwrite. ./lora.sh train --help lists them all.
set -euo pipefail
{
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ ${1:-} == caption || ${1:-} == train ]] || { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 2; }
"$PROJECT_DIR/.venv/bin/python" "$PROJECT_DIR/lib/lora.py" "$@"
exit
}
