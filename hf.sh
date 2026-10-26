#!/usr/bin/env bash
# Run the Hugging Face CLI with its token and cache kept inside this project (matches run.sh).
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export HF_HOME="$PROJECT_DIR/.cache/huggingface"

exec "$PROJECT_DIR/.venv/bin/hf" "$@"
