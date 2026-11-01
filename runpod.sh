#!/usr/bin/env bash
# Rent a GPU on RunPod (runpod.io) as an on-demand compute machine for remote.sh: the web UI, input/ and
# output/ stay on this machine, the rented GPU only computes.
#
#   ./runpod.sh run [options]     rent a pod, set it up, run remote.sh against it, delete the pod when you quit
#   ./runpod.sh up [options]      rent and set up only; then ./runpod.sh connect, and ./runpod.sh down when done
#   ./runpod.sh connect [HOST...] remote.sh against the rented pod, and your own compute machines HOST too
#   ./runpod.sh down              delete the pod (the network volume, with the models, stays)
#   ./runpod.sh extend HOURS      push the pod's time limit back
#   ./runpod.sh offers            GPUs in stock in the volume's data center, then elsewhere
#   ./runpod.sh status | ssh [command]
#   ./runpod.sh volume [delete DC] the network volumes: list them, or delete one with everything on it
#
# Options for up/run:
#   --gpu NAME          GPU as `./runpod.sh offers` lists it (default "RTX 4090")
#   --workflow NAME     download the models of the workflows whose file name contains NAME (repeatable;
#                       default "People Edit Turbo")
#   --hours H           delete the pod after this long (default 3; ./runpod.sh extend adds more)
#   --idle MINUTES      delete the pod after this long without jobs or a connected client (default 30, 0 = off)
#   --datacenter ID     where to rent; creates a network volume there if there is none (default: of the data
#                       centers with a volume, the one with the most of the GPU in stock; with no volume yet,
#                       any such data center, US first)
#   --volume-gb GB      size of a new network volume (default 75)
#   --yes               don't ask before renting
#   --with HOST         run only: also use your compute machine HOST (repeatable), like connect HOST
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
VOLUME_NAME="comfyui"  # and comfyui-<data center> for more volumes
HOST_ALIAS=runpod
REPO_URL="https://github.com/busterb/comfyui.git"
REMOTE_DIR=/workspace/comfyui
DEADLINE_FILE=/root/deadline  # written at the pod's start, moved by ./runpod.sh extend
DEADLINE_HINT="Extend it with ./runpod.sh extend HOURS"
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
  [[ $code == 404 && -n ${HTTP_404_OK:-} ]] && return 0  # the caller handles "not found" (prints nothing)
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
forget_pod() { rm -f "$STATE/pod_id" "$STATE/ssh_config" "$STATE/known_hosts" "$STATE/downloads.json"; }
check_pod() {  # forget a pod that is gone (it deletes itself at its limits); true if one is left
  [[ -n $(pod_id) ]] || return 1
  local out; out="$(HTTP_404_OK=1 rest GET "/pods/$(pod_id)")"
  [[ -n $out ]] && return 0
  echo "pod $(pod_id) is gone (deleted at its time or idle limit)"
  forget_pod
  return 1
}
volumes() {  # this project's network volumes (at most one per data center) as a JSON array
  rest GET /networkvolumes | jq --arg n "$VOLUME_NAME" 'map(select(.name == $n or (.name | startswith($n + "-"))))'
}
availability() {  # GPU_ID -> JSON {data center: stock} where it is in stock
  graphql '{ dataCenters { id listed gpuAvailability { gpuTypeId stockStatus } } }' | jq --arg g "$1" '
    [.dataCenters[] | select(.listed != false) | {id, s: ([.gpuAvailability[]? | select(.gpuTypeId == $g) | .stockStatus][0])}
     | select(.s != null)] | map({(.id): .s}) | add // {}'
}
best_dc() {  # AVAILABILITY_JSON [DATA CENTER...] -> the one with the most stock (US first on ties), or nothing
  local avail="$1"; shift
  jq -rn --argjson a "$avail" --args '($ARGS.positional | if length > 0 then . else ($a | keys) end)
    | map(select($a[.] != null)) | sort_by([{"High": 0, "Medium": 1, "Low": 2}[$a[.]] // 3, (startswith("US") | not)]) | first // empty' "$@"
}
gpu_types() {
  graphql '{ gpuTypes { id displayName memoryInGb securePrice secureCloud } }' | jq '.gpuTypes'
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
# other hosts (your own compute machines next to the pod: ./runpod.sh connect HOST) as usual
Match all
Include ~/.ssh/config
EOF
}

# Deletes the pod it runs on: runpodctl and the pod's own API key are part of RunPod's images
SELF_DELETE='runpodctl remove pod "$RUNPOD_POD_ID" || curl -sS -X DELETE -H "Authorization: Bearer $RUNPOD_API_KEY" "https://rest.runpod.io/v1/pods/$RUNPOD_POD_ID"'

provision() {  # MODELS_JSON IDLE_MINUTES
  provision_project "$1" ""
  if (( $2 > 0 )); then
    ssh_cmd "cat > /root/idle-watchdog.sh; pkill -f '^bash /root/idle-watchdog[.]sh\$'; setsid nohup bash /root/idle-watchdog.sh > /root/idle-watchdog.log 2>&1 < /dev/null &" \
      <<< "$(idle_watchdog "$2")"
  fi
}
idle_watchdog() {  # IDLE_MINUTES -> a script for the pod
  cat <<EOF
# runpod.sh: delete this pod once it went $1 minutes without queued or running jobs, model downloads or SSH
# connections (remote.sh's tunnel)
last=\$(date +%s)
while sleep 60; do
  if python3 - <<'PY'; then last=\$(date +%s); fi
import json, sys, urllib.request
get = lambda p: json.load(urllib.request.urlopen("http://127.0.0.1:8188" + p, timeout=10))
def ssh_connected():  # an established TCP connection on local port 22 (0016), from /proc/net/tcp{,6}
    for f in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            rows = [l.split() for l in open(f).readlines()[1:]]
        except OSError:
            continue
        if any(r[1].endswith(":0016") and r[3] == "01" for r in rows):
            return True
    return False
if ssh_connected():
    sys.exit(0)
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
  (( ${#workflows[@]} )) || workflows=("People Edit Turbo")
  local models; models="$(workflow_models "${workflows[@]}")"
  if check_pod; then  # set up a pod rented before (a run that was interrupted, say)
    echo "continuing with pod $(pod_id), rented before; ./runpod.sh down to drop it"
    start_pod "$models" "$idle"
    return
  fi

  local type gpu_id vol
  type="$(gpu_types | jq --arg g "$gpu" 'map(select((.displayName | ascii_downcase) == ($g | ascii_downcase) or .id == $g)) | first // empty')"
  [[ -n $type ]] || die "no GPU \"$gpu\"; ./runpod.sh offers lists them"
  gpu_id="$(jq -r .id <<< "$type")"
  # The data center: --datacenter; else the one of our volumes' data centers with the most of the GPU in
  # stock; else (no volume yet) any with the most. Pods can only use a volume in their own data center.
  local vols avail where
  vols="$(volumes)" avail="$(availability "$gpu_id")"
  where="$(jq -r 'keys | join(", ")' <<< "$avail")"
  if [[ -z $dc ]]; then
    local vol_dcs; mapfile -t vol_dcs < <(jq -r '.[].dataCenterId' <<< "$vols")
    if (( ${#vol_dcs[@]} )); then
      dc="$(best_dc "$avail" "${vol_dcs[@]}")"
      [[ -n $dc ]] || die "no $gpu in stock where the volumes are (${vol_dcs[*]}); in stock in: ${where:-nowhere right now}.
  Use --datacenter to make a volume in one of those, or try another GPU (./runpod.sh offers)"
    else
      dc="$(best_dc "$avail")"
      [[ -n $dc ]] || die "no data center has a $gpu in stock right now; try another GPU (./runpod.sh offers)"
    fi
  fi
  vol="$(jq --arg d "$dc" 'map(select(.dataCenterId == $d)) | first // empty' <<< "$vols")"
  local price stock_now; price="$(jq -r .securePrice <<< "$type")" stock_now="$(jq -r --arg d "$dc" '.[$d] // "none"' <<< "$avail")"
  echo "$(jq -r '"\(.displayName), \(.memoryInGb) GB"' <<< "$type"): \$$price/h in $dc (stock: $stock_now)"
  echo "limits: deleted after ${hours}h (at most \$$(jq -n "$price * $hours * 100 | ceil / 100")) or ${idle} min without jobs or a client"
  if [[ -n $vol ]]; then
    echo "network volume: $(jq -r '"\(.name) (\(.id)), \(.size) GB"' <<< "$vol") in $dc"
  else
    echo "network volume: none in $dc yet; creates a ${volume_gb} GB one there (billed monthly by size until ./runpod.sh volume delete $dc)"
    echo "  it starts empty: this pod installs the project and downloads the models (about 15 minutes)"
  fi
  [[ $stock_now != none ]] || die "no $gpu in stock in $dc right now; in stock in: ${where:-nowhere right now}"
  if [[ $yes == 0 ]]; then
    read -r -p "Rent it? [y/N] " answer
    [[ $answer == [yY]* ]] || exit 1
  fi

  if [[ -z $vol ]]; then
    local name="$VOLUME_NAME-$dc"
    [[ $(jq length <<< "$vols") == 0 ]] && name="$VOLUME_NAME"  # the first one
    vol="$(rest POST /networkvolumes "$(jq -nc --arg n "$name" --argjson s "$volume_gb" --arg d "$dc" '{name: $n, size: $s, dataCenterId: $d}')")"
    echo "created network volume $(jq -r .id <<< "$vol")"
  fi
  [[ -s $STATE/id_ed25519 ]] || ssh-keygen -q -t ed25519 -N '' -C "runpod.sh" -f "$STATE/id_ed25519"
  # Time limit: a deadline in /root/deadline (./runpod.sh extend moves it), checked every 30 s from the start
  local secs guard; secs="$(jq -n "$hours * 3600 | ceil")"
  guard="echo \$(( \$(date +%s) + $secs )) > /root/deadline; (while :; do d=\$(cat /root/deadline 2>/dev/null); \
[[ \$d =~ ^[0-9]+\$ ]] || d=0; (( \$(date +%s) < d )) || break; sleep 30; done; \
echo \"\$(date): time limit, deleting this pod\"; $SELF_DELETE) > /root/time-limit.log 2>&1 & exec /start.sh"
  local body pod
  body="$(jq -nc --arg img "$IMAGE" --arg g "$gpu_id" --arg v "$(jq -r .id <<< "$vol")" --arg d "$dc" \
    --arg key "$(cat "$STATE/id_ed25519.pub")" \
    --arg start "$guard" \
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

deadline() { ssh_cmd -o BatchMode=yes cat /root/deadline 2>/dev/null; }
deadline_info() {  # DEADLINE -> "deletes itself at 10:15 (in 35 min)"
  jq -rn --argjson t "$1" --argjson now "$(date +%s)" \
    '"the pod deletes itself at \($t | strflocaltime("%H:%M")) (in \(($t - $now) / 60 | floor) min) unless extended: ./runpod.sh extend HOURS"'
}
warn_deadline() {  # while connected: warn 10 and 2 minutes before the time limit
  local warned=999 d left
  while sleep 60; do
    d="$(deadline)" || continue
    left=$(( (d - $(date +%s)) / 60 ))
    if (( left <= 10 && warned > 10 )) || (( left <= 2 && warned > 2 )); then
      printf '\n*** runpod.sh: %s ***\n\n' "$(deadline_info "$d")" >&2
      warned=$left
    fi
    (( left > 10 )) && warned=999  # extended
  done
}

cmd_connect() {
  check_pod && [[ -s $STATE/ssh_config ]] || die "nothing rented (./runpod.sh up)"
  ssh_ready
  local d; d="$(deadline)" && echo "$(deadline_info "$d")"
  warn_deadline &
  local warner=$! rc=0
  SSH_CONFIG="$STATE/ssh_config" "$PROJECT_DIR/remote.sh" "$HOST_ALIAS" "$@" || rc=$?
  kill $warner 2>/dev/null || true
  return $rc
}

cmd_extend() {  # HOURS: move the time limit, counted from the current one (or from now, if that has passed)
  [[ ${1:-} =~ ^[0-9]+([.][0-9]+)?$ ]] || die "usage: ./runpod.sh extend HOURS"
  check_pod || die "no pod rented"
  local secs d; secs="$(jq -n "$1 * 3600 | ceil")"
  d="$(ssh_cmd "d=\$(cat /root/deadline); now=\$(date +%s); (( d > now )) || d=\$now; echo \$(( d + $secs )) > /root/deadline.new && mv /root/deadline.new /root/deadline && cat /root/deadline")"
  deadline_info "$d"
  echo "(at \$$(rest GET "/pods/$(pod_id)" | jq -r .costPerHr)/h)"
}

cmd_down() {
  check_pod || { echo "no pod rented"; return; }
  local id; id="$(pod_id)"
  [[ ! -s $STATE/ssh_config ]] || ssh -F "$STATE/ssh_config" -O exit "$HOST_ALIAS" 2>/dev/null || true
  HTTP_404_OK=1 rest DELETE "/pods/$id" > /dev/null
  echo "deleted pod $id (the network volume stays; ./runpod.sh volume)"
  forget_pod
}

cmd_run() {  # delete the pod however this ends, including a failed setup
  local args=() with=()
  while (( $# )); do  # --with HOST: also compute there; the rest is for up
    if [[ $1 == --with ]]; then with+=("$2"); shift 2; else args+=("$1"); shift; fi
  done
  trap '[[ -z $(pod_id) ]] || { echo; echo "deleting the pod"; cmd_down; }' EXIT
  cmd_up ${args[@]+"${args[@]}"}
  cmd_connect ${with[@]+"${with[@]}"} || true
}

cmd_offers() {  # GPUs in stock where our volumes are (pods can only run there), then elsewhere
  local vol_dcs data rows dc
  mapfile -t vol_dcs < <(volumes | jq -r '.[].dataCenterId')
  data="$(graphql '{ gpuTypes { id displayName memoryInGb securePrice } dataCenters { id listed gpuAvailability { gpuTypeId stockStatus } } }')"
  # one row per GPU type and data center with stock: displayName, GB, price, data center, stock
  rows="$(jq -r '(.gpuTypes | map({(.id): .}) | add) as $t | .dataCenters[] | select(.listed) | .id as $d
    | .gpuAvailability[]? | select(.stockStatus != null and $t[.gpuTypeId] != null) | $t[.gpuTypeId] as $g
    | [$g.displayName, $g.memoryInGb, $g.securePrice, $d, .stockStatus] | @tsv' <<< "$data" | sort -t $'\t' -k3,3n -k1,1)"
  for dc in ${vol_dcs[@]+"${vol_dcs[@]}"}; do
    echo "In $dc, where a network volume is:"
    awk -F'\t' -v dc="$dc" '$4 == dc {printf "  %s\t%s GB\t$%s/h\tstock: %s\n", $1, $2, $3, $5}' <<< "$rows" | column -t -s $'\t'
    awk -F'\t' -v dc="$dc" '$4 == dc {n++} END {exit n > 0}' <<< "$rows" && echo "  (no GPUs in stock there right now)"
    echo
  done
  if (( ${#vol_dcs[@]} )); then
    echo "Elsewhere (./runpod.sh up --datacenter ID makes a volume there):"
  else
    echo "No network volume yet; the first ./runpod.sh up creates one in a data center with the GPU in stock."
    echo "GPUs in stock (Secure Cloud, which network volumes need), by data center:"
  fi
  awk -F'\t' -v skip=" ${vol_dcs[*]-} " 'index(skip, " " $4 " ") == 0 {k = $1 "\t" $2 " GB\t$" $3 "/h"; l[k] = (k in l ? l[k] ", " : "") $4 " (" $5 ")"; if (!(k in o)) o[k] = ++n}
    END {for (k in o) print o[k] "\t" k "\t" l[k]}' <<< "$rows" | sort -n | cut -f2- | sed 's/^/  /' | column -t -s $'\t'
}

cmd_volume() {  # [delete DATACENTER]
  local vols; vols="$(volumes)"
  [[ $(jq length <<< "$vols") != 0 ]] || { echo "no network volumes ($VOLUME_NAME, $VOLUME_NAME-*)"; return; }
  jq -r '.[] | "\(.name)\t\(.id)\t\(.size) GB\t\(.dataCenterId)"' <<< "$vols" | column -t -s $'\t'
  [[ ${1:-} == delete ]] || return 0
  local vol; vol="$(jq --arg d "${2:-}" 'if length == 1 and $d == "" then .[0] else map(select(.dataCenterId == $d)) | first // empty end' <<< "$vols")"
  [[ -n $vol ]] || die "which one? ./runpod.sh volume delete DATACENTER"
  ! check_pod || die "delete the pod first (./runpod.sh down)"
  read -r -p "Delete $(jq -r '"\(.name) in \(.dataCenterId)"' <<< "$vol") and everything on it (models, venv)? [y/N] " answer
  [[ $answer == [yY]* ]] || exit 1
  rest DELETE "/networkvolumes/$(jq -r .id <<< "$vol")" > /dev/null && echo "deleted"
}

# Read in full before running (bash otherwise reads a script as it goes), so editing this file or a git pull
# while it runs can't make it run something else; it ends with exit for the same reason.
{
case "${1:-}" in
  up) shift; cmd_up "$@" ;;
  run) shift; cmd_run "$@" ;;
  connect) shift; cmd_connect "$@" ;;
  extend) shift; cmd_extend "$@" ;;
  down) cmd_down ;;
  status) check_pod || die "no pod rented"; id="$(pod_id)"
          rest GET "/pods/$id" | jq '{id, desiredStatus, costPerHr, gpu: .gpu.displayName, publicIp, portMappings, lastStartedAt}' ;;
  offers) cmd_offers ;;
  volume) shift; cmd_volume "$@" ;;
  ssh) shift; ssh_cmd "$@" ;;
  *) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 2 ;;
esac
exit
}
