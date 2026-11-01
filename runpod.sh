#!/usr/bin/env bash
# Rent a GPU on RunPod (runpod.io) as an on-demand compute machine for remote.sh: the web UI, input/ and
# output/ stay on this machine, the rented GPU only computes.
#
#   ./runpod.sh run [options]     rent a pod, set it up, run remote.sh against it, delete the pod when you quit
#   ./runpod.sh up [options]      rent and set up only; then ./runpod.sh connect, and ./runpod.sh down when done
#   ./runpod.sh connect           remote.sh against the rented pod
#   ./runpod.sh down              delete the pod (the network volume, with the models, stays)
#   ./runpod.sh status | offers | ssh [command]
#   ./runpod.sh volume [delete]   the network volume: show it, or delete it with everything on it
#
# Options for up/run:
#   --gpu NAME          GPU as `./runpod.sh offers` lists it (default "RTX 4090")
#   --workflow NAME     download the models of the workflows whose file name contains NAME (repeatable;
#                       default "People Edit Turbo" and "People Edit 8GB")
#   --hours H           delete the pod after this long (default 3)
#   --idle MINUTES      delete the pod after this long without jobs (default 30, 0 = off)
#   --datacenter ID     where to create the network volume (first run only; default: the one with the most of
#                       the GPU in stock, US first)
#   --volume-gb GB      size of the network volume (first run only; default 75)
#   --yes               don't ask before renting
#
# This project, its venv and the models live on a RunPod network volume (/workspace), which outlives the pods:
# the first pod installs and downloads everything, later ones only start ComfyUI. Pods can only use a volume in
# their own data center. The volume is billed monthly by size, pods by the minute while they exist.
#
# The time limit is enforced on the pod itself from the moment it starts (it deletes itself), so it holds even if
# this machine goes offline; the idle limit starts once the pod is set up. The API key is read from
# RUNPOD_API_KEY or .cache/runpod/api_key (create one at https://console.runpod.io/user/settings). A key made
# for the pods and their host keys are kept in .cache/runpod/ (git-ignored). Pods run this repository at this
# checkout's commit.
set -euo pipefail
shopt -s inherit_errexit  # functions run in $(...) stop at their first error too

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="$PROJECT_DIR/.cache/runpod"
REST="https://rest.runpod.io/v1"
GRAPHQL="https://api.runpod.io/graphql"
IMAGE="runpod/pytorch:2.8.0-py3.11-cuda12.8.1-cudnn-devel-ubuntu22.04"  # for its sshd setup; setup.sh brings its own PyTorch
VOLUME_NAME="comfyui"
HOST_ALIAS=runpod
REPO_URL="https://github.com/busterb/comfyui.git"
REMOTE_DIR=/workspace/comfyui
mkdir -p "$STATE" && chmod 700 "$STATE"

die() { echo "ERROR: $*" >&2; exit 1; }
say() { printf '\n== %s\n' "$*"; }
# shellcheck source=lib/cloud.sh
. "$PROJECT_DIR/lib/cloud.sh"

api_key() {
  if [[ -n ${RUNPOD_API_KEY:-} ]]; then echo "$RUNPOD_API_KEY"
  elif [[ -s $STATE/api_key ]]; then tr -d '[:space:]' < "$STATE/api_key"
  else die "no API key: create one at https://console.runpod.io/user/settings and save it in $STATE/api_key"
  fi
}
http() {  # METHOD URL [JSON body]; the key goes in a header file, not on the command line
  local key hdr; key="$(api_key)"
  hdr="$(mktemp "$STATE/.hdr.XXXXXX")"
  printf 'Authorization: Bearer %s\n' "$key" > "$hdr"
  # Time requests out, and retry the ones that are safe to repeat (not a create)
  local out code attempts=4 i
  [[ $1 == POST && $2 != "$GRAPHQL" ]] && attempts=1
  for (( i = 1; i <= attempts; i++ )); do
    code=000
    if out="$(curl -sS --connect-timeout 15 --max-time 60 -w '\n%{http_code}' -X "$1" -H "@$hdr" \
        -H 'Content-Type: application/json' ${3:+--data "$3"} "$2" 2>&1)"; then
      code="${out##*$'\n'}" out="${out%$'\n'*}"
      [[ $code == 5* ]] || break
    fi
    (( i < attempts )) && { echo "  (RunPod API: ${code/#000/no answer}, retrying)" >&2; sleep $(( i * 5 )); }
  done
  rm -f "$hdr"
  [[ $code != 000 ]] || die "RunPod API $1 ${2#https://}: no answer ($out)"
  if [[ $code != 2* ]]; then
    die "RunPod API $1 ${2#https://}: HTTP $code $(jq -r '(.error // .message // .)|tostring' <<< "$out" 2>/dev/null || echo "$out")"
  fi
  echo "$out"
}
rest() { http "$1" "$REST$2" "${3:-}"; }
graphql() {  # QUERY -> .data, or dies with the errors
  local out; out="$(http POST "$GRAPHQL" "$(jq -nc --arg q "$1" '{query: $q}')")"
  jq -e '.errors | not' <<< "$out" >/dev/null || die "RunPod API: $(jq -r '[.errors[].message] | join("; ")' <<< "$out")"
  jq '.data' <<< "$out"
}

pod_id() { [[ -s $STATE/pod_id ]] && cat "$STATE/pod_id"; }
volume() {  # the network volume's JSON, or nothing
  rest GET /networkvolumes | jq --arg n "$VOLUME_NAME" 'map(select(.name == $n)) | first // empty'
}
gpu_types() {
  graphql '{ gpuTypes { id displayName memoryInGb securePrice secureCloud } }' | jq '.gpuTypes'
}
stock() {  # DATACENTER GPU_ID -> High/Medium/Low/none
  graphql '{ dataCenters { id gpuAvailability { gpuTypeId stockStatus } } }' |
    jq -r --arg d "$1" --arg g "$2" '.dataCenters[] | select(.id == $d) | .gpuAvailability[]? | select(.gpuTypeId == $g) | .stockStatus // empty' |
    head -1 | grep . || echo none
}

write_ssh_config() {  # HOST PORT
  cat > "$STATE/ssh_config" <<EOF
# Written by runpod.sh for the RunPod pod $(pod_id); remote.sh gets it through SSH_CONFIG
Host $HOST_ALIAS
  HostName $1
  Port $2
  User root
  IdentityFile $STATE/id_ed25519
  IdentitiesOnly yes
  UserKnownHostsFile $STATE/known_hosts
  StrictHostKeyChecking accept-new
  ServerAliveInterval 30
  ControlMaster auto
  ControlPath ${XDG_RUNTIME_DIR:-/tmp}/comfyui-ssh-%C
  ControlPersist 10m
EOF
}

# Deletes the pod it runs on: runpodctl and the pod's own API key are part of RunPod's images
SELF_DELETE='runpodctl remove pod "$RUNPOD_POD_ID" || curl -sS -X DELETE -H "Authorization: Bearer $RUNPOD_API_KEY" "https://rest.runpod.io/v1/pods/$RUNPOD_POD_ID"'

provision() {  # MODELS_JSON IDLE_MINUTES
  provision_project "$1" ""
  if (( $2 > 0 )); then
    ssh_cmd "cat > /root/idle-watchdog.sh; pkill -f '[i]dle-watchdog.sh'; setsid nohup bash /root/idle-watchdog.sh > /root/idle-watchdog.log 2>&1 < /dev/null &" \
      <<< "$(idle_watchdog "$2")"
  fi
}
idle_watchdog() {  # IDLE_MINUTES -> a script for the pod
  cat <<EOF
# runpod.sh: delete this pod once it went $1 minutes without queued or running jobs or model downloads
last=\$(date +%s)
while sleep 60; do
  if python3 - <<'PY'; then last=\$(date +%s); fi
import json, sys, urllib.request
get = lambda p: json.load(urllib.request.urlopen("http://127.0.0.1:8188" + p, timeout=10))
try:
    q, d = get("/queue"), get("/server_models/status")
except Exception:
    sys.exit(1)
sys.exit(0 if q["queue_running"] or q["queue_pending"] or any(j["state"] in ("queued", "downloading") for j in d) else 1)
PY
  if (( \$(date +%s) - last >= $1 * 60 )); then
    echo "\$(date): no jobs for $1 minutes, deleting this pod"
    $SELF_DELETE
    exit
  fi
done
EOF
}

cmd_up() {
  local gpu="RTX 4090" hours=3 idle=30 dc="" volume_gb=75 yes=0 workflows=()
  while (( $# )); do
    case "$1" in
      --gpu) gpu="$2"; shift ;;
      --workflow) workflows+=("$2"); shift ;;
      --hours) hours="$2"; shift ;;
      --idle) idle="$2"; shift ;;
      --datacenter) dc="$2"; shift ;;
      --volume-gb) volume_gb="$2"; shift ;;
      --yes) yes=1 ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
  (( ${#workflows[@]} )) || workflows=("People Edit Turbo" "People Edit 8GB")
  local models; models="$(workflow_models "${workflows[@]}")"
  if [[ -n $(pod_id) ]]; then  # set up a pod rented before (a run that was interrupted, say)
    echo "continuing with pod $(pod_id), rented before; ./runpod.sh down to drop it"
    start_pod "$models" "$idle"
    return
  fi

  local type gpu_id vol
  type="$(gpu_types | jq --arg g "$gpu" 'map(select((.displayName | ascii_downcase) == ($g | ascii_downcase) or .id == $g)) | first // empty')"
  [[ -n $type ]] || die "no GPU \"$gpu\"; ./runpod.sh offers lists them"
  gpu_id="$(jq -r .id <<< "$type")"
  vol="$(volume)"
  if [[ -n $vol ]]; then
    dc="$(jq -r .dataCenterId <<< "$vol")"
  elif [[ -z $dc ]]; then  # a data center with the GPU in stock, preferring plenty
    dc="$(graphql '{ dataCenters { id listed gpuAvailability { gpuTypeId stockStatus } } }' | jq -r --arg g "$gpu_id" '
      [.dataCenters[] | select(.listed != false) | {id, s: ([.gpuAvailability[]? | select(.gpuTypeId == $g) | .stockStatus][0])}
       | select(.s == "High" or .s == "Medium" or .s == "Low")]
      | sort_by([{"High": 0, "Medium": 1, "Low": 2}[.s], (.id | startswith("US") | not)]) | first.id // empty')"
    [[ -n $dc ]] || die "no data center has a $gpu in stock right now; try another GPU (./runpod.sh offers)"
  fi
  local price stock_now; price="$(jq -r .securePrice <<< "$type")" stock_now="$(stock "$dc" "$gpu_id")"
  echo "$(jq -r '"\(.displayName), \(.memoryInGb) GB"' <<< "$type"): \$$price/h in $dc (stock: $stock_now)"
  echo "limits: deleted after ${hours}h (at most \$$(jq -n "$price * $hours * 100 | ceil / 100")) or ${idle} min without jobs"
  if [[ -n $vol ]]; then
    echo "network volume: $(jq -r '"\(.id), \(.size) GB"' <<< "$vol") in $dc"
  else
    echo "network volume: none yet; creates a ${volume_gb} GB one in $dc (billed monthly by size until ./runpod.sh volume delete)"
  fi
  [[ $stock_now != none ]] || die "no $gpu in stock in $dc right now; try another GPU (./runpod.sh offers) or later"
  if [[ $yes == 0 ]]; then
    read -r -p "Rent it? [y/N] " answer
    [[ $answer == [yY]* ]] || exit 1
  fi

  if [[ -z $vol ]]; then
    vol="$(rest POST /networkvolumes "$(jq -nc --arg n "$VOLUME_NAME" --argjson s "$volume_gb" --arg d "$dc" '{name: $n, size: $s, dataCenterId: $d}')")"
    echo "created network volume $(jq -r .id <<< "$vol")"
  fi
  [[ -s $STATE/id_ed25519 ]] || ssh-keygen -q -t ed25519 -N '' -C "runpod.sh" -f "$STATE/id_ed25519"
  local deadline=$(( $(jq -n "$hours * 3600 | ceil") ))
  local body pod
  body="$(jq -nc --arg img "$IMAGE" --arg g "$gpu_id" --arg v "$(jq -r .id <<< "$vol")" --arg d "$dc" \
    --arg key "$(cat "$STATE/id_ed25519.pub")" \
    --arg start "(sleep $deadline; echo \"\$(date): time limit, deleting this pod\"; $SELF_DELETE) > /root/time-limit.log 2>&1 & exec /start.sh" \
    '{name: "comfyui-remote", imageName: $img, gpuTypeIds: [$g], gpuCount: 1, cloudType: "SECURE",
      networkVolumeId: $v, volumeMountPath: "/workspace", dataCenterIds: [$d], containerDiskInGb: 20,
      ports: ["22/tcp"], env: {PUBLIC_KEY: $key}, dockerStartCmd: ["bash", "-c", $start]}')"
  pod="$(rest POST /pods "$body")"
  jq -r .id <<< "$pod" > "$STATE/pod_id"
  [[ $(pod_id) != null ]] || { rm -f "$STATE/pod_id"; die "no pod id in $(jq -c . <<< "$pod")"; }
  rm -f "$STATE/known_hosts" "$STATE/ssh_config"
  echo "pod $(pod_id): \$$(jq -r .costPerHr <<< "$pod")/h"
  start_pod "$models" "$idle"
}

start_pod() {  # MODELS_JSON IDLE_MINUTES: wait for SSH, provision
  local pod ip port
  say "Waiting for the pod to start"
  for _ in $(seq 1 90); do
    pod="$(rest GET "/pods/$(pod_id)")"
    [[ $(jq -r .desiredStatus <<< "$pod") == RUNNING ]] || die "pod $(pod_id) is $(jq -r .desiredStatus <<< "$pod")"
    ip="$(jq -r '.publicIp // empty' <<< "$pod")" port="$(jq -r '.portMappings["22"] // empty' <<< "$pod")"
    [[ -n $ip && -n $port ]] && break
    sleep 10
  done
  [[ -n $ip && -n $port ]] || die "pod $(pod_id) has no SSH address after 15 minutes (./runpod.sh down)"
  write_ssh_config "$ip" "$port"
  ssh_ready
  ssh_cmd 'nvidia-smi --query-gpu=name,memory.total --format=csv,noheader' || die "the pod has no working GPU (./runpod.sh down)"
  provision "$1" "$2"
  say "Ready: ./runpod.sh connect (and ./runpod.sh down when you're done)"
}

cmd_connect() {
  [[ -n $(pod_id) && -s $STATE/ssh_config ]] || die "nothing rented (./runpod.sh up)"
  ssh_ready
  SSH_CONFIG="$STATE/ssh_config" "$PROJECT_DIR/remote.sh" "$HOST_ALIAS" "$@"
}

cmd_down() {
  local id; id="$(pod_id)" || { echo "no pod rented"; return; }
  [[ ! -s $STATE/ssh_config ]] || ssh -F "$STATE/ssh_config" -O exit "$HOST_ALIAS" 2>/dev/null || true
  rest DELETE "/pods/$id" > /dev/null
  echo "deleted pod $id (the network volume stays; ./runpod.sh volume)"
  rm -f "$STATE/pod_id" "$STATE/ssh_config" "$STATE/known_hosts" "$STATE/downloads.json"
}

cmd_run() {  # delete the pod however this ends, including a failed setup
  trap '[[ -z $(pod_id) ]] || { echo; echo "deleting the pod"; cmd_down; }' EXIT
  cmd_up "$@"
  cmd_connect || true
}

cmd_volume() {
  local vol; vol="$(volume)"
  [[ -n $vol ]] || { echo "no network volume named $VOLUME_NAME"; return; }
  jq -c . <<< "$vol"
  [[ ${1:-} == delete ]] || return 0
  [[ -z $(pod_id) ]] || die "delete the pod first (./runpod.sh down)"
  read -r -p "Delete the volume and everything on it (models, venv)? [y/N] " answer
  [[ $answer == [yY]* ]] || exit 1
  rest DELETE "/networkvolumes/$(jq -r .id <<< "$vol")" > /dev/null && echo "deleted"
}

case "${1:-}" in
  up) shift; cmd_up "$@" ;;
  run) shift; cmd_run "$@" ;;
  connect) shift; cmd_connect "$@" ;;
  down) cmd_down ;;
  status) id="$(pod_id)" || die "no pod rented"
          rest GET "/pods/$id" | jq '{id, desiredStatus, costPerHr, gpu: .gpu.displayName, publicIp, portMappings, lastStartedAt}' ;;
  offers) graphql '{ gpuTypes { displayName memoryInGb lowestPrice(input: {gpuCount: 1, secureCloud: true}) { stockStatus uninterruptablePrice } } }' |
            jq -r '.gpuTypes | map(select(.lowestPrice.stockStatus != null)) | sort_by(.lowestPrice.uninterruptablePrice)[] |
              "\(.displayName)\t\(.memoryInGb) GB\t$\(.lowestPrice.uninterruptablePrice)/h\tstock: \(.lowestPrice.stockStatus)"' |
            column -t -s $'\t'
          echo "(Secure Cloud GPUs available now, which network volumes need; a volume's own data center may have fewer)" ;;
  volume) shift; cmd_volume "$@" ;;
  ssh) shift; ssh_cmd "$@" ;;
  *) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 2 ;;
esac
