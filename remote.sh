#!/usr/bin/env bash
# Run ComfyUI here as a client of another machine's ComfyUI: the web UI, input/ and output/ stay on this machine,
# the models and the compute stay on the other one (see custom_nodes/remote_compute).
#
#   ./remote.sh HOST                  e.g. ./remote.sh promaxgb10-4b16
#   COMFYUI_PORT=8190 ./remote.sh HOST   local port (default 8188, or the first free one from 8190 if that's taken,
#                                     e.g. by this machine's own ComfyUI)
#   REMOTE_PORT=8188                  ComfyUI's port on HOST (it only listens on HOST's localhost)
#   SSH_CONFIG=FILE                   ssh config to use instead of ~/.ssh/config
#
# HOST needs this project set up (setup.sh) with ComfyUI running. The connection goes through an SSH tunnel,
# so HOST's ComfyUI stays bound to its localhost. Extra arguments are passed on to run.sh.
set -euo pipefail

# Read in full before running (bash otherwise reads a script as it goes), so editing this file or a git pull
# while it runs can't make it run something else; it ends with exit for the same reason.
{

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST="${1:?usage: ./remote.sh HOST [run.sh arguments]}"
shift
REMOTE_PORT="${REMOTE_PORT:-8188}"
SSH=(ssh)
[[ -z ${SSH_CONFIG:-} ]] || SSH+=(-F "$SSH_CONFIG")  # an ssh config of its own (cloud.sh's rented GPU)

port_free() { ! (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
first_free() { for p in "$@"; do port_free "$p" && { echo "$p"; return; }; done; echo "no free port among $*" >&2; exit 1; }
if [[ -z ${COMFYUI_PORT:-} ]]; then
  export COMFYUI_PORT="$(first_free 8188 $(seq 8190 8199))"
  [[ $COMFYUI_PORT == 8188 ]] || echo "port 8188 is in use (this machine's own ComfyUI?); using $COMFYUI_PORT"
fi
TUNNEL_PORT="${TUNNEL_PORT:-$(first_free $(seq 18188 18199))}"

FORWARD="$TUNNEL_PORT:127.0.0.1:$REMOTE_PORT"
"${SSH[@]}" -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -L "$FORWARD" "$HOST" &
TUNNEL=$!
# With SSH connection sharing (ControlMaster) the forward lives in the shared master connection and would
# outlast this script: cancel it there too (a no-op without sharing)
COMFY=
cleanup() {  # under set -e, so every step may fail quietly (the processes may be gone already)
  [[ -z $COMFY ]] || kill $COMFY 2>/dev/null || true
  kill $TUNNEL 2>/dev/null || true
  for _ in 1 2 3 4 5; do  # confirm the port is closed; retry if the cancel didn't take yet
    "${SSH[@]}" -O cancel -L "$FORWARD" "$HOST" 2>/dev/null || true
    port_free "$TUNNEL_PORT" && break
    sleep 1
  done
}
trap cleanup EXIT
trap 'exit 130' INT TERM
echo "connecting to ComfyUI on $HOST:$REMOTE_PORT..."
reachable() { curl -s --max-time 5 -o /dev/null "http://127.0.0.1:$TUNNEL_PORT/"; }
for _ in $(seq 1 15); do reachable && break; kill -0 $TUNNEL 2>/dev/null || break; sleep 1; done
reachable || { echo "ComfyUI on $HOST:$REMOTE_PORT is not reachable. Is it running there? (systemctl --user start comfyui, or ./run.sh)" >&2; exit 1; }

# --cpu: nothing is computed here, so don't claim this machine's GPU. Own asset database per port (an index of
# the local files), so this can run next to this machine's own ComfyUI and other clients
COMFYUI_REMOTE_URL="http://127.0.0.1:$TUNNEL_PORT" "$PROJECT_DIR/run.sh" --cpu \
  --database-url "sqlite:///$PROJECT_DIR/ComfyUI/user/comfyui-client-$COMFYUI_PORT.db" "$@" &
COMFY=$!
wait $COMFY
exit
}
