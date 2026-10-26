#!/usr/bin/env bash
# Run ComfyUI here as a client of another machine's ComfyUI: the web UI, input/ and output/ stay on this machine,
# the models and the compute stay on the other one (see custom_nodes/remote_compute).
#
#   ./remote.sh HOST                  e.g. ./remote.sh promaxgb10-4b16
#   COMFYUI_PORT=8190 ./remote.sh HOST   local port (default 8188; pick another if this machine's own ComfyUI runs)
#   REMOTE_PORT=8188                  ComfyUI's port on HOST (it only listens on HOST's localhost)
#
# HOST needs this project set up (setup.sh) with ComfyUI running. The connection goes through an SSH tunnel,
# so HOST's ComfyUI stays bound to its localhost. Extra arguments are passed on to run.sh.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST="${1:?usage: ./remote.sh HOST [run.sh arguments]}"
shift
REMOTE_PORT="${REMOTE_PORT:-8188}"
TUNNEL_PORT="${TUNNEL_PORT:-18188}"

ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -L "$TUNNEL_PORT:127.0.0.1:$REMOTE_PORT" "$HOST" &
TUNNEL=$!
trap 'kill $TUNNEL 2>/dev/null' EXIT
for _ in $(seq 1 30); do curl -s -o /dev/null "http://127.0.0.1:$TUNNEL_PORT/" && break; sleep 1; done
curl -s -o /dev/null "http://127.0.0.1:$TUNNEL_PORT/" || { echo "ComfyUI on $HOST:$REMOTE_PORT is not reachable through the tunnel" >&2; exit 1; }

# --cpu: nothing is computed here, so don't claim this machine's GPU. Own asset database (an index of the local
# files), so this can run next to this machine's own ComfyUI
COMFYUI_REMOTE_URL="http://127.0.0.1:$TUNNEL_PORT" "$PROJECT_DIR/run.sh" --cpu \
  --database-url "sqlite:///$PROJECT_DIR/ComfyUI/user/comfyui-client.db" "$@" &
COMFY=$!
trap 'kill $COMFY $TUNNEL 2>/dev/null' EXIT INT TERM
wait $COMFY
