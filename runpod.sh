#!/usr/bin/env bash
# Rent a GPU on RunPod (runpod.io) as an on-demand compute machine for remote.sh: the web UI, input/ and
# output/ stay on this machine, the rented GPU only computes.
#
#   ./runpod.sh run [options]     rent pods, set them up, run remote.sh against them, delete them when you quit
#   ./runpod.sh up [options]      rent and set up only; then ./runpod.sh connect, and ./runpod.sh down when done
#   ./runpod.sh connect [HOST...] remote.sh against the rented pods, and your own compute machines HOST too
#   ./runpod.sh down              delete the pods (the network volume, with the models, stays)
#   ./runpod.sh extend HOURS      push the pods' time limit back
#   ./runpod.sh offers            GPUs in stock in the volume's data center, then elsewhere
#   ./runpod.sh status
#   ./runpod.sh ssh [POD] [command]   POD: runpod (the first pod, the default), runpod2, ...
#   ./runpod.sh volume            list the network volumes
#   ./runpod.sh volume grow GB [DC]   enlarge one to GB (it can't shrink again; billed by size)
#   ./runpod.sh volume delete DC  delete one with everything on it
#
# Options for up/run:
#   --gpu NAME          GPU as `./runpod.sh offers` lists it (default "RTX 4090"). Give it more than once to rent
#                       more pods, e.g. --gpu "RTX 4090" --gpu "RTX 4090": jobs then run on all of them at once
#   --workflow NAME     download the models of the workflows whose file name contains NAME (repeatable;
#                       default "People Edit Turbo")
#   --hours H           delete the pods after this long (default 3; ./runpod.sh extend adds more)
#   --idle MINUTES      delete a pod after this long without jobs or a connected client (default 30, 0 = off)
#   --datacenter ID     where to rent; creates a network volume there if there is none (default: of the data
#                       centers with a volume, the one with the most of the GPU in stock; with no volume yet,
#                       any such data center, US first)
#   --gpus-per-pod N    GPUs in each pod (default 1); each runs its own ComfyUI, so a pod takes N jobs at once
#   --wait MINUTES      if the GPUs aren't in stock, keep checking (every 3 s) for up to this long and rent them
#                       the moment they are; you confirm the quote first (default 0: don't wait)
#   --volume-gb GB      size of a new network volume (default 75)
#   --yes               don't ask before renting
#   --dry-run           everything but renting: show what would be rented, and when (with --wait)
#   --with HOST         run only: also use your compute machine HOST (repeatable), like connect HOST
#
# This project, its venv and the models live on a RunPod network volume (/workspace), which outlives the pods:
# the first pod installs and downloads everything, later ones only start ComfyUI. Pods can only use a volume in
# their own data center, and several pods share it: they are set up one after another, and each keeps its
# ComfyUI database on its own disk. The volume is billed monthly by size, pods by the minute while they exist.
#
# The time limit is enforced on the pod itself from the moment it starts (it deletes itself), so it holds even if
# this machine goes offline; the idle limit starts once the pod is set up. The API key is read from
# RUNPOD_API_KEY or .cache/runpod/api_key (create one at https://console.runpod.io/user/settings). A key made
# for the pods and their host keys are kept in .cache/runpod/ (git-ignored). Pods run this repository at this
# checkout's commit.
set -euo pipefail
shopt -s inherit_errexit  # functions run in $(...) stop at their first error too

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${RUNPOD_STATE:-$PROJECT_DIR/.cache/runpod}"  # RUNPOD_STATE: another one (for testing)
REST="https://rest.runpod.io/v1"
GRAPHQL="https://api.runpod.io/graphql"
IMAGE="runpod/pytorch:2.8.0-py3.11-cuda12.8.1-cudnn-devel-ubuntu22.04"  # for its sshd setup; setup.sh brings its own PyTorch
VOLUME_NAME="comfyui"  # and comfyui-<data center> for more volumes
HOST_ALIAS=runpod  # the first pod; more are runpod2, runpod3, ...
REPO_URL="https://github.com/busterb/comfyui.git"
REMOTE_DIR=/workspace/comfyui
DEADLINE_FILE=/root/deadline  # written at the pod's start, moved by ./runpod.sh extend
DEADLINE_HINT="Extend it with ./runpod.sh extend HOURS"
COMFYUI_ARGS="--database-url sqlite:////root/comfyui.db"  # not on the volume, which other pods may share
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
      [[ $code == 5* || $code == 429 ]] || break  # 429: too many requests
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

# The rented pods, one "ID ALIAS GPUS" line each, in .cache/runpod/pods. A pod_id file is a pod rented by the
# single-pod version of this script (perhaps still running it): it is read as the pod "runpod", not rewritten.
pods() {
  { [[ ! -s $STATE/pod_id ]] || echo "$(cat "$STATE/pod_id") $HOST_ALIAS"
    [[ ! -s $STATE/pods ]] || cat "$STATE/pods"; } | awk '!seen[$1]++'
}
pod_ids() { pods | awk '{print $1}'; }
aliases() { pods | awk '{print $2}'; }
gpus_of() { pods | awk -v a="$1" '$2 == a {print ($3 == "" ? 1 : $3); exit}'; }  # ALIAS -> its number of GPUs
servers() {  # the pods' ComfyUI instances for remote.sh: ALIAS for the first, ALIAS:PORT for more
  local alias i
  for alias in $(aliases); do
    echo "$alias"
    for (( i = 1; i < $(gpus_of "$alias"); i++ )); do echo "$alias:$(( 8188 + i ))"; done
  done
}
forget_pod() {  # ID
  local alias; alias="$(pods | awk -v id="$1" '$1 == id {print $2}')"
  [[ -z $alias ]] || { rm -f "$STATE/hosts/$alias"; ssh -F "$STATE/ssh_config" -O exit "$alias" 2>/dev/null || true; }
  [[ ! -s $STATE/pod_id || $(cat "$STATE/pod_id") != "$1" ]] || rm -f "$STATE/pod_id"
  [[ ! -s $STATE/pods ]] || { awk -v id="$1" '$1 != id' "$STATE/pods" > "$STATE/pods.new"; mv "$STATE/pods.new" "$STATE/pods"; }
  write_ssh_config
}
check_pods() {  # forget pods that are gone (they delete themselves at their limits); true if any are left
  local id out
  for id in $(pod_ids); do
    out="$(HTTP_404_OK=1 rest GET "/pods/$id")"
    [[ -n $out ]] && continue
    echo "pod $id is gone (deleted at its time or idle limit)"
    forget_pod "$id"
  done
  [[ -n $(pods) ]]
}
volumes() {  # this project's network volumes (at most one per data center) as a JSON array
  rest GET /networkvolumes | jq --arg n "$VOLUME_NAME" 'map(select(.name == $n or (.name | startswith($n + "-"))))'
}
availability() {  # GPU_ID -> JSON {data center: stock} where it is in stock
  graphql '{ dataCenters { id listed gpuAvailability { gpuTypeId stockStatus } } }' | jq --arg g "$1" '
    [.dataCenters[] | select(.listed != false)  # a type may be listed more than once: take its best stock
     | {id, s: ([.gpuAvailability[]? | select(.gpuTypeId == $g and .stockStatus != null) | .stockStatus]
                | min_by({"High": 0, "Medium": 1, "Low": 2}[.] // 3))}
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

write_ssh_config() {  # from .cache/runpod/hosts/ALIAS ("HOST PORT"), one block per pod
  local alias host port
  {
    echo "# Written by runpod.sh for the rented pods; remote.sh gets it through SSH_CONFIG"
    for alias in $(aliases); do
      [[ -s $STATE/hosts/$alias ]] || continue
      read -r host port < "$STATE/hosts/$alias"
      cat <<EOF
Host $alias
  HostName $host
  Port $port
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
    done
    echo "# other hosts (your own compute machines next to the pods: ./runpod.sh connect HOST) as usual"
    echo "Match all"
    echo "Include ~/.ssh/config"
  } > "$STATE/ssh_config"
}

# Deletes the pod it runs on: runpodctl and the pod's own API key are part of RunPod's images
SELF_DELETE='runpodctl remove pod "$RUNPOD_POD_ID" || curl -sS -X DELETE -H "Authorization: Bearer $RUNPOD_API_KEY" "https://rest.runpod.io/v1/pods/$RUNPOD_POD_ID"'

provision() {  # MODELS_JSON IDLE_MINUTES, on the pod HOST_ALIAS
  INSTANCES="$(gpus_of "$HOST_ALIAS")" provision_project "$1" ""
  if (( $2 > 0 )); then
    ssh_cmd "cat > /root/idle-watchdog.sh; pkill -f '^bash /root/idle-watchdog[.]sh\$'; setsid nohup bash /root/idle-watchdog.sh > /root/idle-watchdog.log 2>&1 < /dev/null &" \
      <<< "$(idle_watchdog "$2" "$(gpus_of "$HOST_ALIAS")")"
  fi
}
idle_watchdog() {  # IDLE_MINUTES INSTANCES -> a script for the pod
  cat <<EOF
# runpod.sh: delete this pod once it went $1 minutes without queued or running jobs, model downloads or SSH
# connections (remote.sh's tunnel)
last=\$(date +%s)
while sleep 60; do
  if python3 - <<'PY'; then last=\$(date +%s); fi
import json, sys, urllib.request
get = lambda port, p: json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}" + p, timeout=10))
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
for port in range(8188, 8188 + $2):  # every ComfyUI instance on the pod
    try:
        q, d = get(port, "/queue"), get(port, "/server_models/status")
    except Exception:
        continue
    if q["queue_running"] or q["queue_pending"] or any(j["state"] in ("queued", "downloading") for j in d):
        sys.exit(0)
sys.exit(1)
PY
  if (( \$(date +%s) - last >= $1 * 60 )); then
    echo "\$(date): no jobs for $1 minutes, deleting this pod"
    $SELF_DELETE
    exit
  fi
done
EOF
}

refresh_stock() {  # sets the caller's avails (per type: {data center: stock}), avail (where all are) and where
  local t
  avails=()
  for t in "${types[@]}"; do avails+=("$(availability "$(jq -r .id <<< "$t")")"); done
  # where all of them are in stock: {data center: worst stock} over the data centers that have every one
  avail="$(jq -s 'map(to_entries | map({(.key): .value}) | add // {}) as $a
    | ($a[0] | keys) | map(select(. as $d | all($a[]; has($d)))) | map({(.): ([$a[][.]] | max_by({"High": 0, "Medium": 1, "Low": 2}[.]))}) | add // {}' \
    <<< "$(printf '%s\n' "${avails[@]}")")"
  where="$(jq -r 'keys | join(", ")' <<< "$avail")"
}
pick_dc() {  # the data center to rent in now, or nothing: --datacenter; else of our volumes' data centers the one
  # with the most stock; else (no volume yet) any with the most. Pods can only use a volume in their own data center.
  if [[ -n $fixed_dc ]]; then
    jq -e --arg d "$fixed_dc" 'has($d)' <<< "$avail" > /dev/null && echo "$fixed_dc"
  elif (( ${#vol_dcs[@]} )); then
    best_dc "$avail" "${vol_dcs[@]}"
  else
    best_dc "$avail"
  fi
  return 0
}

cmd_up() {
  local gpus=() hours=3 idle=30 fixed_dc="" volume_gb=75 yes=0 workflows=() per_pod=1 wait=0 dry=0
  while (( $# )); do
    case "$1" in
      --gpu) gpus+=("$2"); shift ;;
      --gpus-per-pod) per_pod="$2"; shift ;;
      --workflow) workflows+=("$2"); shift ;;
      --hours) hours="$2"; shift ;;
      --idle) idle="$2"; shift ;;
      --datacenter) fixed_dc="$2"; shift ;;
      --volume-gb) volume_gb="$2"; shift ;;
      --wait) wait="$2"; shift ;;
      --yes) yes=1 ;;
      --dry-run) dry=1 yes=1 ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
  [[ $per_pod =~ ^[1-8]$ ]] || die "--gpus-per-pod takes 1 to 8"
  [[ $wait =~ ^[0-9]+$ ]] || die "--wait takes whole minutes"
  (( ${#gpus[@]} )) || gpus=("RTX 4090")
  (( ${#workflows[@]} )) || workflows=("People Edit Turbo")
  local models; models="$(workflow_models "${workflows[@]}")"
  if [[ $dry == 0 ]] && check_pods; then  # set up pods rented before (a run that was interrupted, say)
    echo "continuing with the pods rented before ($(aliases | paste -sd' ')); ./runpod.sh down to drop them"
    start_pods "$models" "$idle"
    return
  fi

  # The GPU types, and where they are in stock
  local all_types g type types=() avails=() avail where
  all_types="$(gpu_types)"
  for g in "${gpus[@]}"; do
    type="$(jq --arg g "$g" 'map(select((.displayName | ascii_downcase) == ($g | ascii_downcase) or .id == $g)) | first // empty' <<< "$all_types")"
    [[ -n $type ]] || die "no GPU \"$g\"; ./runpod.sh offers lists them"
    types+=("$type")
  done
  refresh_stock
  local vols vol_dcs; vols="$(volumes)"
  mapfile -t vol_dcs < <(jq -r '.[].dataCenterId' <<< "$vols")
  local dc; dc="$(pick_dc)"

  # The quote. Without stock now, it is for where the pods would go: --datacenter, or a volume's data center
  local qdc="${dc:-${fixed_dc:-${vol_dcs[0]:-}}}"
  local i total=0 price stock_now missing=()
  for i in "${!types[@]}"; do
    price="$(jq -n "$(jq -r .securePrice <<< "${types[$i]}") * $per_pod")"
    stock_now="$( [[ -z $qdc ]] && echo none || jq -r --arg d "$qdc" '.[$d] // "none"' <<< "${avails[$i]}")"
    total="$(jq -n "$total + $price")"
    echo "pod $(( i + 1 )): $(( per_pod > 1 ? per_pod : 1 ))× $(jq -r '"\(.displayName), \(.memoryInGb) GB"' <<< "${types[$i]}"): \$$price/h in ${qdc:-a data center with stock} (stock: $stock_now)"
    [[ $stock_now != none ]] || missing+=("${gpus[$i]}")
  done
  (( ${#types[@]} == 1 )) || echo "together: \$$total/h"
  echo "limits: deleted after ${hours}h (at most \$$(jq -n "$total * $hours * 100 | ceil / 100")) or ${idle} min without jobs or a client"
  local vol; vol="$(jq --arg d "$qdc" 'map(select(.dataCenterId == $d)) | first // empty' <<< "$vols")"
  if [[ -n $vol ]]; then
    echo "network volume: $(jq -r '"\(.name) (\(.id)), \(.size) GB"' <<< "$vol") in $qdc"
  else
    echo "network volume: none in ${qdc:-that data center} yet; creates a ${volume_gb} GB one there (billed monthly by size until ./runpod.sh volume delete DC)"
    echo "  it starts empty: the first pod installs the project and downloads the models (about 15 minutes)"
  fi
  (( ${#types[@]} == 1 && per_pod == 1 )) || echo "(stock is reported per GPU type, not per card, so not all of these may be available)"
  if [[ -z $dc ]] || (( ${#missing[@]} )); then
    (( wait > 0 )) || die "not in stock in ${qdc:-any data center} right now: ${missing[*]:-${gpus[*]}}; all in stock in: ${where:-nowhere right now}
  (--wait MINUTES waits for them)"
    echo "not in stock right now: ${missing[*]:-${gpus[*]}}. Waiting up to $wait min, renting the moment they are."
    (( ${#types[@]} == 1 )) || echo "  pods rented while waiting for the others are billed from then on"
  fi
  if [[ $yes == 0 ]]; then
    read -r -p "Rent $( (( ${#types[@]} == 1 )) && echo it || echo them)? [y/N] " answer
    [[ $answer == [yY]* ]] || exit 1
  fi

  [[ -s $STATE/id_ed25519 ]] || ssh-keygen -q -t ed25519 -N '' -C "runpod.sh" -f "$STATE/id_ed25519"
  # Time limit: a deadline in /root/deadline (./runpod.sh extend moves it), checked every 30 s from the start
  local secs guard; secs="$(jq -n "$hours * 3600 | ceil")"
  guard="echo \$(( \$(date +%s) + $secs )) > /root/deadline; (while :; do d=\$(cat /root/deadline 2>/dev/null); \
[[ \$d =~ ^[0-9]+\$ ]] || d=0; (( \$(date +%s) < d )) || break; sleep 30; done; \
echo \"\$(date): time limit, deleting this pod\"; $SELF_DELETE) > /root/time-limit.log 2>&1 & exec /start.sh"
  [[ $dry == 1 ]] || { rm -f "$STATE/known_hosts"; mkdir -p "$STATE/hosts"; rm -f "$STATE/hosts/"*; }

  # Rent, and with --wait keep trying (stock can be gone within seconds) until every pod is rented or time is up
  local todo=("${!types[@]}") until=$(( $(date +%s) + wait * 60 )) next_note=0 left body pod id alias name
  while :; do
    if [[ -n $dc ]]; then
      if [[ -z $vol ]] || [[ $(jq -r .dataCenterId <<< "$vol") != "$dc" ]]; then
        vol="$(jq --arg d "$dc" 'map(select(.dataCenterId == $d)) | first // empty' <<< "$vols")"
      fi
      if [[ -z $vol && $dry == 1 ]]; then
        echo "dry run: would create a ${volume_gb} GB network volume in $dc"
        vol="$(jq -nc --arg d "$dc" '{id: "dry-run", dataCenterId: $d}')"
      elif [[ -z $vol ]]; then
        name="$VOLUME_NAME-$dc"; [[ $(jq length <<< "$vols") == 0 ]] && name="$VOLUME_NAME"  # the first one
        vol="$(rest POST /networkvolumes "$(jq -nc --arg n "$name" --argjson s "$volume_gb" --arg d "$dc" '{name: $n, size: $s, dataCenterId: $d}')")"
        vols="$(volumes)" vol_dcs=("$dc")
        echo "created network volume $(jq -r .id <<< "$vol") in $dc"
      fi
      left=()
      for i in "${todo[@]}"; do
        if ! jq -e --arg d "$dc" 'has($d)' <<< "${avails[$i]}" > /dev/null; then left+=("$i"); continue; fi
        if [[ $dry == 1 ]]; then
          echo "dry run: $(date +%H:%M:%S) would rent pod $(( i + 1 )) (${per_pod}× ${gpus[$i]}) in $dc, stock $(jq -r --arg d "$dc" '.[$d]' <<< "${avails[$i]}")"
          continue
        fi
        body="$(jq -nc --arg img "$IMAGE" --arg g "$(jq -r .id <<< "${types[$i]}")" --argjson n "$per_pod" \
          --arg v "$(jq -r .id <<< "$vol")" --arg d "$dc" --arg key "$(cat "$STATE/id_ed25519.pub")" --arg start "$guard" \
          '{name: "comfyui-remote", imageName: $img, gpuTypeIds: [$g], gpuCount: $n, cloudType: "SECURE",
            networkVolumeId: $v, volumeMountPath: "/workspace", dataCenterIds: [$d], containerDiskInGb: 20,
            ports: ["22/tcp"], env: {PUBLIC_KEY: $key}, dockerStartCmd: ["bash", "-c", $start]}')"
        if ! pod="$(rest POST /pods "$body" 2>&1)" || [[ $(jq -r '.id // "null"' <<< "$pod" 2>/dev/null) == null ]]; then
          (( wait > 0 )) || echo "couldn't rent pod $(( i + 1 )) (${gpus[$i]}): ${pod#ERROR: }" >&2
          left+=("$i"); continue
        fi
        id="$(jq -r .id <<< "$pod")"
        alias="$HOST_ALIAS"; [[ -z $(pods) ]] || alias="$HOST_ALIAS$(( $(pods | wc -l) + 1 ))"
        echo "$id $alias $per_pod" >> "$STATE/pods"
        echo "rented pod $id ($alias, ${per_pod}× $(jq -r '.gpu.displayName // empty' <<< "$pod")): \$$(jq -r .costPerHr <<< "$pod")/h"
        fixed_dc="$dc"  # the rest must share its volume
      done
      todo=(${left[@]+"${left[@]}"})
    fi
    (( ${#todo[@]} )) || break
    (( $(date +%s) < until )) || break
    if (( $(date +%s) >= next_note )); then
      echo "  $(date +%H:%M) waiting for: $(for i in "${todo[@]}"; do printf '%s ' "${gpus[$i]}"; done)($(( (until - $(date +%s)) / 60 )) min left)"
      next_note=$(( $(date +%s) + 300 ))
    fi
    sleep 3
    refresh_stock
    dc="$(pick_dc)"
  done
  [[ $dry == 0 ]] || { (( ${#todo[@]} == 0 )) && echo "dry run: done" || echo "dry run: not all in stock within $wait min"; return 0; }
  [[ -n $(pods) ]] || die "no pods could be rented$( (( wait > 0 )) && echo " within $wait min")"
  (( ${#todo[@]} == 0 )) || echo "couldn't rent: $(for i in "${todo[@]}"; do printf '%s ' "${gpus[$i]}"; done); going on with the pods there are" >&2
  start_pods "$models" "$idle"
}

start_pods() {  # MODELS_JSON IDLE_MINUTES: wait for each pod, set it up; one at a time, as they share the volume
  local id alias pod ip port n=0
  for id in $(pod_ids); do
    alias="$(pods | awk -v id="$id" '$1 == id {print $2}')"
    say "Waiting for pod $id ($alias) to start"
    ip= port=
    for _ in $(seq 1 90); do
      pod="$(rest GET "/pods/$id")"
      [[ $(jq -r .desiredStatus <<< "$pod") == RUNNING ]] || die "pod $id is $(jq -r .desiredStatus <<< "$pod")"
      ip="$(jq -r '.publicIp // empty' <<< "$pod")" port="$(jq -r '.portMappings["22"] // empty' <<< "$pod")"
      [[ -n $ip && -n $port ]] && break
      sleep 10
    done
    [[ -n $ip && -n $port ]] || die "pod $id has no SSH address after 15 minutes (./runpod.sh down)"
    mkdir -p "$STATE/hosts"; echo "$ip $port" > "$STATE/hosts/$alias"
    write_ssh_config
    HOST_ALIAS="$alias"
    ssh_ready
    ssh_cmd 'nvidia-smi --query-gpu=name,memory.total --format=csv,noheader' || die "pod $id has no working GPU (./runpod.sh down)"
    provision "$1" "$2"
    n=$(( n + 1 ))
  done
  HOST_ALIAS=runpod
  say "Ready ($n pod$( (( n == 1 )) || echo s)): ./runpod.sh connect (and ./runpod.sh down when you're done)"
}

deadline() { ssh_cmd -o BatchMode=yes cat /root/deadline 2>/dev/null; }  # of the pod HOST_ALIAS
earliest_deadline() {
  local alias d best=""
  for alias in $(aliases); do
    d="$(HOST_ALIAS="$alias" deadline)" || continue
    [[ -z $best ]] || (( d < best )) && best="$d"
  done
  [[ -n $best ]] && echo "$best"
}
deadline_info() {  # DEADLINE -> "deletes itself at 10:15 (in 35 min)"
  jq -rn --argjson t "$1" --argjson now "$(date +%s)" \
    '"the pods delete themselves at \($t | strflocaltime("%H:%M")) (in \(($t - $now) / 60 | floor) min) unless extended: ./runpod.sh extend HOURS"'
}
warn_deadline() {  # while connected: warn 10 and 2 minutes before the (earliest) time limit
  local warned=999 d left
  while sleep 60; do
    d="$(earliest_deadline)" || continue
    left=$(( (d - $(date +%s)) / 60 ))
    if (( left <= 10 && warned > 10 )) || (( left <= 2 && warned > 2 )); then
      printf '\n*** runpod.sh: %s ***\n\n' "$(deadline_info "$d")" >&2
      warned=$left
    fi
    (( left > 10 )) && warned=999  # extended
  done
}

cmd_connect() {
  check_pods && [[ -s $STATE/ssh_config ]] || die "nothing rented (./runpod.sh up)"
  local alias
  for alias in $(aliases); do HOST_ALIAS="$alias" ssh_ready; done
  local d; d="$(earliest_deadline)" && echo "$(deadline_info "$d")"
  warn_deadline &
  local warner=$! rc=0
  # the pods first: they are what you are paying for
  SSH_CONFIG="$STATE/ssh_config" "$PROJECT_DIR/remote.sh" $(servers) "$@" || rc=$?
  kill $warner 2>/dev/null || true
  return $rc
}

cmd_extend() {  # HOURS: move the time limits, counted from the current ones (or from now, if they have passed)
  [[ ${1:-} =~ ^[0-9]+([.][0-9]+)?$ ]] || die "usage: ./runpod.sh extend HOURS"
  check_pods || die "no pod rented"
  local secs alias; secs="$(jq -n "$1 * 3600 | ceil")"
  for alias in $(aliases); do
    HOST_ALIAS="$alias" ssh_cmd "d=\$(cat /root/deadline); now=\$(date +%s); (( d > now )) || d=\$now; echo \$(( d + $secs )) > /root/deadline.new && mv /root/deadline.new /root/deadline" ||
      echo "couldn't extend $alias" >&2
  done
  local d; d="$(earliest_deadline)" && deadline_info "$d"
  echo "(at \$$(for id in $(pod_ids); do rest GET "/pods/$id" | jq .costPerHr; done | jq -s add)/h)"
}

cmd_down() {
  check_pods || { echo "no pod rented"; return; }
  local id
  for id in $(pod_ids); do
    HTTP_404_OK=1 rest DELETE "/pods/$id" > /dev/null
    echo "deleted pod $id"
    forget_pod "$id"
  done
  rm -f "$STATE/known_hosts" "$STATE/downloads.json"
  echo "(the network volume stays; ./runpod.sh volume)"
}

cmd_run() {  # delete the pods however this ends, including a failed setup
  local args=() with=()
  while (( $# )); do  # --with HOST: also compute there; the rest is for up
    if [[ $1 == --with ]]; then with+=("$2"); shift 2; else args+=("$1"); shift; fi
  done
  trap '[[ -z $(pods) ]] || { echo; echo "deleting the pods"; cmd_down; }' EXIT
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

cmd_volume() {  # [grow GB [DATACENTER] | delete DATACENTER]
  local vols; vols="$(volumes)"
  [[ $(jq length <<< "$vols") != 0 ]] || { echo "no network volumes ($VOLUME_NAME, $VOLUME_NAME-*)"; return; }
  jq -r '.[] | "\(.name)\t\(.id)\t\(.size) GB\t\(.dataCenterId)"' <<< "$vols" | column -t -s $'\t'
  local action="${1:-}" gb="" dc
  case $action in
    "") return 0 ;;
    grow) gb="${2:-}" dc="${3:-}"
          [[ $gb =~ ^[0-9]+$ ]] || die "usage: ./runpod.sh volume grow GB [DATACENTER]" ;;
    delete) dc="${2:-}" ;;
    *) die "usage: ./runpod.sh volume [grow GB [DATACENTER] | delete DATACENTER]" ;;
  esac
  local vol; vol="$(jq --arg d "$dc" 'if length == 1 and $d == "" then .[0] else map(select(.dataCenterId == $d)) | first // empty end' <<< "$vols")"
  [[ -n $vol ]] || die "which one? ./runpod.sh volume $action ${gb:+$gb }DATACENTER"
  if [[ $action == grow ]]; then
    local size; size="$(jq -r .size <<< "$vol")"
    (( gb > size )) || die "it is $size GB already; a volume can only grow"
    read -r -p "Grow $(jq -r '"\(.name) in \(.dataCenterId)"' <<< "$vol") from $size to $gb GB? It can't shrink again. [y/N] " answer
    [[ $answer == [yY]* ]] || exit 1
    rest PATCH "/networkvolumes/$(jq -r .id <<< "$vol")" "$(jq -nc --argjson s "$gb" '{size: $s}')" |
      jq -r '"now \(.size) GB"'
    return
  fi
  ! check_pods || die "delete the pods first (./runpod.sh down)"
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
  status) check_pods || die "no pod rented"
          while read -r id alias; do
            rest GET "/pods/$id" | jq -c --arg a "$alias" '{alias: $a, id, desiredStatus, costPerHr, gpu: .gpu.displayName, lastStartedAt}'
          done < <(pods) ;;
  offers) cmd_offers ;;
  volume) shift; cmd_volume "$@" ;;
  ssh) shift; [[ -n ${1:-} ]] && aliases | grep -qx -- "$1" && { HOST_ALIAS="$1"; shift; }; ssh_cmd "$@" ;;
  *) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 2 ;;
esac
exit
}
