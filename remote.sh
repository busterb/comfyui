#!/usr/bin/env bash
# Run ComfyUI here as a client of other machines' ComfyUI: the web UI, input/ and output/ stay on this machine,
# the models and the compute are on the others (see custom_nodes/remote_compute).
#
#   ./remote.sh HOST                  e.g. ./remote.sh promaxgb10-4b16
#   ./remote.sh HOST HOST...          several compute machines: as many jobs run at once, each on the first
#                                     free machine in this order (put the fastest first)
#   ./remote.sh HOST -- ARGS          ARGS go to run.sh (so does anything from the first argument starting with -)
#   COMFYUI_PORT=8190 ./remote.sh HOST   local port (default 8188, or the first free one from 8190 if that's taken,
#                                     e.g. by this machine's own ComfyUI)
#   REMOTE_PORT=8188                  ComfyUI's port on the hosts (it only listens on their localhost)
#   SSH_CONFIG=FILE                   ssh config to use instead of ~/.ssh/config
#
# Each HOST needs this project set up (setup.sh) with ComfyUI running, and the same models as the first one.
# The connections go through SSH tunnels, so the hosts' ComfyUI stays bound to their localhost. A host that
# can't be reached is left out, as long as one can.
set -euo pipefail

# Read in full before running (bash otherwise reads a script as it goes), so editing this file or a git pull
# while it runs can't make it run something else; it ends with exit for the same reason.
{

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTS=()
while (( $# )) && [[ $1 != -* ]]; do HOSTS+=("$1"); shift; done
[[ ${1:-} == -- ]] && shift
(( ${#HOSTS[@]} )) || { echo "usage: ./remote.sh HOST [HOST...] [-- run.sh arguments]" >&2; exit 2; }
REMOTE_PORT="${REMOTE_PORT:-8188}"
SSH=(ssh)
[[ -z ${SSH_CONFIG:-} ]] || SSH+=(-F "$SSH_CONFIG")  # an ssh config of its own (runpod.sh's rented GPU)

port_free() { ! (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
first_free() { for p in "$@"; do port_free "$p" && { echo "$p"; return; }; done; echo "no free port among $*" >&2; exit 1; }
if [[ -z ${COMFYUI_PORT:-} ]]; then
  export COMFYUI_PORT="$(first_free 8188 $(seq 8190 8199))"
  [[ $COMFYUI_PORT == 8188 ]] || echo "port 8188 is in use (this machine's own ComfyUI?); using $COMFYUI_PORT"
fi

# One tunnel per host. With SSH connection sharing (ControlMaster) a forward lives in the shared master
# connection and would outlast this script, so cleanup cancels it there too (a no-op without sharing).
FORWARDS=() TUNNELS=() URLS=() COMFY=
cleanup() {  # under set -e, so every step may fail quietly (the processes may be gone already)
  [[ -z $COMFY ]] || kill $COMFY 2>/dev/null || true
  local i
  for i in "${!FORWARDS[@]}"; do
    kill "${TUNNELS[$i]}" 2>/dev/null || true
    for _ in 1 2 3 4 5; do  # confirm the port is closed; retry if the cancel didn't take yet
      "${SSH[@]}" -O cancel -L "${FORWARDS[$i]}" "${HOSTS[$i]}" 2>/dev/null || true
      port_free "${FORWARDS[$i]%%:*}" && break
      sleep 1
    done
  done
}
trap cleanup EXIT
trap 'exit 130' INT TERM
for host in "${HOSTS[@]}"; do
  port="$(first_free $(seq 18188 18199))"
  FORWARDS+=("$port:127.0.0.1:$REMOTE_PORT")
  "${SSH[@]}" -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -L "${FORWARDS[${#FORWARDS[@]}-1]}" "$host" &
  TUNNELS+=($!)
  # wait for this one before the next, so the next picks another free port
  for _ in $(seq 1 15); do port_free "$port" || break; kill -0 "${TUNNELS[${#TUNNELS[@]}-1]}" 2>/dev/null || break; sleep 1; done
done
reachable() { curl -s --max-time 5 -o /dev/null "http://127.0.0.1:$1/"; }
for i in "${!HOSTS[@]}"; do
  port="${FORWARDS[$i]%%:*}"
  echo "connecting to ComfyUI on ${HOSTS[$i]}:$REMOTE_PORT..."
  for _ in $(seq 1 15); do reachable "$port" && break; kill -0 "${TUNNELS[$i]}" 2>/dev/null || break; sleep 1; done
  if reachable "$port"; then
    URLS+=("http://127.0.0.1:$port")
  else
    echo "ComfyUI on ${HOSTS[$i]}:$REMOTE_PORT is not reachable. Is it running there? (systemctl --user start comfyui, or ./run.sh)" >&2
  fi
done
(( ${#URLS[@]} )) || exit 1
(( ${#URLS[@]} == ${#HOSTS[@]} )) || echo "continuing with the ${#URLS[@]} reachable compute machine(s)"

# --cpu: nothing is computed here, so don't claim this machine's GPU. Own asset database per port (an index of
# the local files), so this can run next to this machine's own ComfyUI and other clients
COMFYUI_REMOTE_URL="$(IFS=,; echo "${URLS[*]}")" "$PROJECT_DIR/run.sh" --cpu \
  --database-url "sqlite:///$PROJECT_DIR/ComfyUI/user/comfyui-client-$COMFYUI_PORT.db" "$@" &
COMFY=$!
wait $COMFY
exit
}
