#!/usr/bin/env bash
# Rent a GPU on CloudGPU (cloudgpu.app) as an on-demand compute machine for remote.sh: the web UI, input/ and
# output/ stay on this machine, the rented GPU only computes.
#
#   ./cloud.sh run [options]     rent and provision, run remote.sh against it, destroy it when remote.sh exits
#   ./cloud.sh up [options]      rent and provision only; then ./cloud.sh connect, and ./cloud.sh down when done
#   ./cloud.sh connect           remote.sh against the rented GPU
#   ./cloud.sh down              destroy it (its disk is erased; nothing of yours is kept there)
#   ./cloud.sh status | list | offers | ssh [command]
#
# Options for up/run:
#   --gpu MODEL         GPU model as `./cloud.sh offers` lists it (default "RTX 4090")
#   --workflow NAME     download the models of the workflows whose file name contains NAME (repeatable;
#                       default "People Edit Turbo" and "People Edit 8GB")
#   --max-spend USD     budget for this instance (default 5)
#   --hours H           time limit (default 3)
#   --idle MINUTES      destroy after the GPU was idle this long (default 30, minimum 10, 0 = off)
#   --yes               don't ask before renting
#
# CloudGPU enforces the limits on its side, so the instance goes away even if this machine sleeps or this
# script dies. The API key is read from CLOUDGPU_API_KEY or .cache/cloudgpu/api_key (create one at
# https://cloudgpu.app/api). The instance's SSH password, a key made for it and its host key are kept in
# .cache/cloudgpu/ (git-ignored), and the instance runs this repository at this checkout's commit.
set -euo pipefail
shopt -s inherit_errexit  # functions run in $(...) stop at their first error too

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="$PROJECT_DIR/.cache/cloudgpu"
API="https://cloudgpu.app/v1/gpu"
HOST_ALIAS=cloudgpu
REPO_URL="https://github.com/busterb/comfyui.git"
REMOTE_DIR=/root/comfyui
mkdir -p "$STATE" && chmod 700 "$STATE"

die() { echo "ERROR: $*" >&2; exit 1; }
say() { printf '\n== %s\n' "$*"; }

api_key() {
  if [[ -n ${CLOUDGPU_API_KEY:-} ]]; then echo "$CLOUDGPU_API_KEY"
  elif [[ -s $STATE/api_key ]]; then tr -d '[:space:]' < "$STATE/api_key"
  else die "no API key: create one at https://cloudgpu.app/api and save it in $STATE/api_key"
  fi
}
api() {  # METHOD PATH [JSON body]; the key goes in a header file, not on the command line
  local key hdr; key="$(api_key)"
  hdr="$(mktemp "$STATE/.hdr.XXXXXX")"
  printf 'Authorization: Bearer %s\n' "$key" > "$hdr"
  # The API sometimes stalls: time requests out, and retry the ones that are safe to repeat (not a create)
  local out code attempts=4 i
  [[ $1 == POST ]] && attempts=1
  for (( i = 1; i <= attempts; i++ )); do
    code=000
    if out="$(curl -sS --connect-timeout 15 --max-time 60 -w '\n%{http_code}' -X "$1" -H "@$hdr" \
        -H 'Content-Type: application/json' ${3:+--data "$3"} "$API$2" 2>&1)"; then
      code="${out##*$'\n'}" out="${out%$'\n'*}"
      [[ $code == 5* ]] || break
    fi
    (( i < attempts )) && { echo "  (CloudGPU API: ${code/#000/no answer}, retrying)" >&2; sleep $(( i * 5 )); }
  done
  rm -f "$hdr"
  [[ $code != 000 ]] || die "CloudGPU API $1 $2: no answer ($out)"
  if [[ $code != 2* ]]; then
    die "CloudGPU API $1 $2: HTTP $code $(jq -r '.error.message? // .' <<< "$out" 2>/dev/null || echo "$out")"
  fi
  echo "$out"
}

instance_id() { [[ -s $STATE/instance_id ]] && cat "$STATE/instance_id"; }
public() { jq 'del(.ssh)'; }  # instance JSON without the login

ssh_cmd() { ssh -F "$STATE/ssh_config" "$HOST_ALIAS" "$@"; }
ssh_ready() {  # wait for a working (shared) connection, which later ssh_cmd calls then reuse
  for _ in $(seq 1 10); do ssh_cmd -o BatchMode=yes -o ConnectTimeout=20 true 2>/dev/null && return; sleep 10; done
  die "can't connect to the instance over SSH"
}

write_ssh_config() {  # HOST PORT USER
  cat > "$STATE/ssh_config" <<EOF
# Written by cloud.sh for the rented instance $(instance_id); remote.sh gets it through SSH_CONFIG
Host $HOST_ALIAS
  HostName $1
  Port $2
  User $3
  IdentityFile $STATE/id_ed25519
  IdentitiesOnly yes
  UserKnownHostsFile $STATE/known_hosts
  StrictHostKeyChecking accept-new
  ServerAliveInterval 30
  # One connection for everything: the provider's SSH entry point sometimes drops new connections
  ControlMaster auto
  ControlPath $STATE/cm-%C
  ControlPersist 10m
EOF
}

install_key() {  # log in once with the password, add a key made for this instance
  [[ -s $STATE/id_ed25519 ]] || ssh-keygen -q -t ed25519 -N '' -C "cloud.sh" -f "$STATE/id_ed25519"
  local askpass="$STATE/askpass"
  printf '#!/bin/sh\ncat %q\n' "$STATE/password" > "$askpass" && chmod 700 "$askpass"
  for _ in $(seq 1 20); do
    if SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force ssh -F "$STATE/ssh_config" \
        -o IdentitiesOnly=yes -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive \
        -o ConnectTimeout=15 -o NumberOfPasswordPrompts=1 "$HOST_ALIAS" \
        'umask 077 && mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys' < "$STATE/id_ed25519.pub" 2>"$STATE/ssh.err"; then
      rm -f "$askpass" "$STATE/password"  # the key does from here on
      ssh_cmd -o BatchMode=yes true && return
      die "the key was added but key login fails"
    fi
    sleep 5  # sshd may not be up yet
  done
  rm -f "$askpass"
  die "can't log in to the instance: $(tail -1 "$STATE/ssh.err")"
}

workflow_models() {  # NAME... -> JSON array of {name, url, directory} from the matching workflows
  local files=() name f
  for name in "$@"; do
    local found=0
    for f in "$PROJECT_DIR"/workflows/*.json; do
      [[ $(basename "$f") == *"$name"* ]] && files+=("$f") found=1
    done
    [[ $found == 1 ]] || die "no workflow matches \"$name\" in workflows/"
  done
  jq -s '[.[] | .. | objects | select(has("models")) | .models[]? | select(type == "object" and .url and .name and .directory)
          | {name, url, directory}] | unique_by(.directory + "/" + .name)' "${files[@]}"
}

provision() {  # MODELS_JSON
  local commit; commit="$(git -C "$PROJECT_DIR" rev-parse HEAD)"
  git -C "$PROJECT_DIR" branch -r --contains "$commit" 2>/dev/null | grep -q . ||
    echo "warning: $commit isn't pushed; the instance runs the newest pushed commit instead"
  say "Installing this project on the instance (PyTorch and ComfyUI: a few minutes)"
  ssh_cmd "bash -s" <<EOF
set -euo pipefail
command -v git >/dev/null && command -v curl >/dev/null || { apt-get update -qq && apt-get install -y -qq git curl; }
[[ -d $REMOTE_DIR/.git ]] || git clone -q "$REPO_URL" $REMOTE_DIR
cd $REMOTE_DIR
git fetch -q origin && { git checkout -q "$commit" 2>/dev/null || git checkout -q origin/main; }
./setup.sh --no-service > setup.log 2>&1 || { tail -30 setup.log; exit 1; }
grep -E '^torch .* OK on' setup.log || true
pgrep -f "[m]ain.py --listen 127.0.0.1" >/dev/null || setsid nohup ./run.sh > comfyui.log 2>&1 < /dev/null &
for _ in \$(seq 1 120); do curl -s -o /dev/null http://127.0.0.1:8188/ && exit 0; sleep 2; done
tail -30 comfyui.log; exit 1
EOF
  say "Downloading $(jq length <<< "$1") models onto the instance"
  jq -r '.[] | "  \(.directory)/\(.name)"' <<< "$1"
  ssh_cmd "curl -sS -X POST -H 'Content-Type: application/json' --data-binary @- http://127.0.0.1:8188/server_models/download" \
    <<< "$(jq -c '{models: .}' <<< "$1")" > "$STATE/downloads.json"
  jq -e 'map(select(.state == "error")) | length == 0' "$STATE/downloads.json" >/dev/null ||
    die "$(jq -r '.[] | select(.state == "error") | "\(.name): \(.error)"' "$STATE/downloads.json")"
  local status
  while :; do
    status="$(ssh_cmd curl -sS http://127.0.0.1:8188/server_models/status)"
    jq -r '[.[] | select(.state == "queued" or .state == "downloading")] |
           "  \(map(.done) | add // 0 | . / 1e9 | floor) GB done, \(length) files to go"' <<< "$status"
    jq -e 'any(.[]; .state == "queued" or .state == "downloading")' <<< "$status" >/dev/null || break
    sleep 15
  done
  jq -e 'any(.[]; .state == "error")' <<< "$status" >/dev/null &&
    die "$(jq -r '.[] | select(.state == "error") | "\(.name): \(.error)"' <<< "$status")"
  return 0
}

cmd_up() {
  local gpu="RTX 4090" spend=5 hours=3 idle=30 yes=0 workflows=()
  while (( $# )); do
    case "$1" in
      --gpu) gpu="$2"; shift ;;
      --workflow) workflows+=("$2"); shift ;;
      --max-spend) spend="$2"; shift ;;
      --hours) hours="$2"; shift ;;
      --idle) idle="$2"; shift ;;
      --yes) yes=1 ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
  (( ${#workflows[@]} )) || workflows=("People Edit Turbo" "People Edit 8GB")
  local models; models="$(workflow_models "${workflows[@]}")"
  if [[ -n $(instance_id) ]]; then  # set up an instance rented before (a run that was interrupted, say)
    local id; id="$(instance_id)"
    echo "continuing with instance $id, rented before ($(api GET "/instances/$id" | jq -r .status)); ./cloud.sh down to drop it"
    start_instance "$id" "$models"
    return
  fi

  local offer account
  offer="$(api GET /offers | jq --arg g "$gpu" '.data[] | select((.gpu_model | ascii_downcase) == ($g | ascii_downcase))')"
  [[ -n $offer ]] || die "no GPU \"$gpu\"; ./cloud.sh offers lists them"
  account="$(api GET /account)"
  echo "$(jq -r '"\(.gpu_model), \(.vram_gb // "?") GB: $\(.hourly_usd)/h, availability \(.available)"' <<< "$offer")"
  echo "limits: \$$spend, ${hours}h, destroyed after ${idle} min idle; balance \$$(jq -r '.balance_usd | tonumber * 100 | round / 100' <<< "$account")"
  [[ $(jq -r .available <<< "$offer") != none ]] || die "$gpu is out of stock; pick another (./cloud.sh offers)"
  if [[ $yes == 0 ]]; then
    read -r -p "Rent it? [y/N] " answer
    [[ $answer == [yY]* ]] || exit 1
  fi

  local body inst id
  body="$(jq -nc --arg g "$(jq -r .gpu_model <<< "$offer")" --argjson s "$spend" --argjson h "$hours" --argjson i "$idle" \
    '{gpu_model: $g, gpu_count: 1, max_minutes: ($h * 60 | ceil), max_spend_usd: $s, idle_minutes: $i}')"
  inst="$(api POST /instances "$body")"
  id="$(jq -r .id <<< "$inst")"
  [[ $id != null ]] || die "no instance id in $(public <<< "$inst")"
  echo "$id" > "$STATE/instance_id"
  rm -f "$STATE/known_hosts" "$STATE/ssh_config"
  echo "instance $id: $(jq -r .status <<< "$inst")"

  start_instance "$id" "$models"
}

start_instance() {  # ID MODELS_JSON: wait for it to run, log in, provision
  local id="$1" inst status
  say "Waiting for the instance to start"
  for _ in $(seq 1 120); do
    inst="$(api GET "/instances/$id")" status="$(jq -r .status <<< "$inst")"
    [[ $status == running ]] && [[ $(jq -r '.ssh.host // empty' <<< "$inst") ]] && break
    [[ $status == creating || $status == running ]] || die "instance $id is $status: $(public <<< "$inst" | jq -c .)"
    sleep 10
  done
  [[ $status == running ]] || die "instance $id isn't running after 20 minutes (./cloud.sh down)"
  if [[ ! -s $STATE/ssh_config ]] || ! ssh_cmd -o BatchMode=yes -o ConnectTimeout=15 true 2>/dev/null; then
    (umask 077; jq -r .ssh.password <<< "$inst" > "$STATE/password")
    write_ssh_config "$(jq -r .ssh.host <<< "$inst")" "$(jq -r .ssh.port <<< "$inst")" "$(jq -r '.ssh.user // "root"' <<< "$inst")"
    install_key
  fi
  ssh_ready
  ssh_cmd 'nvidia-smi --query-gpu=name,memory.total --format=csv,noheader' || die "the instance has no working GPU (./cloud.sh down)"
  provision "$models"
  say "Ready: ./cloud.sh connect (and ./cloud.sh down when you're done)"
}

cmd_connect() {
  [[ -n $(instance_id) && -s $STATE/ssh_config ]] || die "nothing rented (./cloud.sh up)"
  ssh_ready
  SSH_CONFIG="$STATE/ssh_config" "$PROJECT_DIR/remote.sh" "$HOST_ALIAS" "$@"
}

cmd_down() {
  local id; id="$(instance_id)" || { echo "nothing rented"; return; }
  [[ ! -s $STATE/ssh_config ]] || ssh -F "$STATE/ssh_config" -O exit "$HOST_ALIAS" 2>/dev/null || true
  api DELETE "/instances/$id" | public | jq -c '{id, status, gpu_model, minutes: (.running_minutes // .minutes), cost_usd: (.cost_usd // .cost)}'
  rm -f "$STATE/instance_id" "$STATE/password" "$STATE/ssh_config" "$STATE/known_hosts" "$STATE/downloads.json"
}

cmd_run() {  # destroy the instance however this ends, including a failed provisioning
  trap '[[ -z $(instance_id) ]] || { echo; echo "destroying the instance"; cmd_down; }' EXIT
  cmd_up "$@"
  cmd_connect || true
}

case "${1:-}" in
  up) shift; cmd_up "$@" ;;
  run) shift; cmd_run "$@" ;;
  connect) shift; cmd_connect "$@" ;;
  down) cmd_down ;;
  status) id="$(instance_id)" || die "nothing rented"; api GET "/instances/$id" | public ;;
  list) api GET /instances | jq '.data | map(del(.ssh))' ;;
  offers) api GET /offers | jq -r '.data[] | "\(.gpu_model)\t\(.vram_gb // "?") GB\t$\(.hourly_usd)/h\t\(.available)"' | column -t -s $'\t' ;;
  ssh) shift; ssh_cmd "$@" ;;
  *) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 2 ;;
esac
