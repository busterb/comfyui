#!/usr/bin/env bash
# Rent a GPU on CloudGPU (cloudgpu.app) as an on-demand compute machine for remote.sh: the web UI, input/ and
# output/ stay on this machine, the rented GPU only computes.
#
#   ./cloudgpu.sh run [options]     rent and provision, run remote.sh against it, destroy it when remote.sh exits
#   ./cloudgpu.sh up [options]      rent and provision only; then ./cloudgpu.sh connect, and ./cloudgpu.sh down when done
#   ./cloudgpu.sh connect           remote.sh against the rented GPU
#   ./cloudgpu.sh down              destroy it (its disk is erased; nothing of yours is kept there)
#   ./cloudgpu.sh status | list | offers | ssh [command]
#
# Options for up/run:
#   --gpu MODEL         GPU model as `./cloudgpu.sh offers` lists it (default "RTX 4090")
#   --workflow NAME     download the models of the workflows whose file name contains NAME (repeatable;
#                       default "People Edit 8GB", whose models are the smallest: about 10 GB)
#   --max-spend USD     budget for this instance (default 5)
#   --hours H           time limit (default 3)
#   --idle MINUTES      destroy after the GPU was idle this long (default 60, minimum 10, 0 = off). Setting up
#                       and downloading count as idle too.
#   --yes               don't ask before renting
#
# CloudGPU instances have no persistent storage, so every rental downloads its models again, and their machines
# have downloaded from Hugging Face at only 1-7 MB/s, so this suits workflows with small models.
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
DEADLINE_FILE=/root/deadline  # the time limit CloudGPU enforces (it may also stop earlier, at the spending cap)
DEADLINE_HINT="CloudGPU's limit is set when renting (./cloudgpu.sh up --hours) and can't be extended"
mkdir -p "$STATE" && chmod 700 "$STATE"

die() { echo "ERROR: $*" >&2; exit 1; }
say() { printf '\n== %s\n' "$*"; }
# shellcheck source=lib/cloud.sh
. "$PROJECT_DIR/lib/cloud.sh"

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


write_ssh_config() {  # HOST PORT USER
  cat > "$STATE/ssh_config" <<EOF
# Written by cloudgpu.sh for the rented instance $(instance_id); remote.sh gets it through SSH_CONFIG
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
  ControlPath ${XDG_RUNTIME_DIR:-/tmp}/comfyui-ssh-%C
  ControlPersist 10m
EOF
}

install_key() {  # log in once with the password, add a key made for this instance
  [[ -s $STATE/id_ed25519 ]] || ssh-keygen -q -t ed25519 -N '' -C "cloudgpu.sh" -f "$STATE/id_ed25519"
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

provision() {  # MODELS_JSON
  provision_project "$1" \
    'command -v git >/dev/null && command -v curl >/dev/null || { apt-get update -qq && apt-get install -y -qq git curl > /dev/null 2>&1; }'
}

cmd_up() {
  local gpu="RTX 4090" spend=5 hours=3 idle=60 yes=0 workflows=()
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
  (( ${#workflows[@]} )) || workflows=("People Edit 8GB")
  local models; models="$(workflow_models "${workflows[@]}")"
  if [[ -n $(instance_id) ]]; then  # set up an instance rented before (a run that was interrupted, say)
    local id; id="$(instance_id)"
    echo "continuing with instance $id, rented before ($(api GET "/instances/$id" | jq -r .status)); ./cloudgpu.sh down to drop it"
    start_instance "$id" "$models"
    return
  fi

  local offer account
  offer="$(api GET /offers | jq --arg g "$gpu" '.data[] | select((.gpu_model | ascii_downcase) == ($g | ascii_downcase))')"
  [[ -n $offer ]] || die "no GPU \"$gpu\"; ./cloudgpu.sh offers lists them"
  account="$(api GET /account)"
  echo "$(jq -r '"\(.gpu_model), \(.vram_gb // "?") GB: $\(.hourly_usd)/h, availability \(.available)"' <<< "$offer")"
  echo "limits: \$$spend, ${hours}h, destroyed after ${idle} min idle; balance \$$(jq -r '.balance_usd | tonumber * 100 | round / 100' <<< "$account")"
  [[ $(jq -r .available <<< "$offer") != none ]] || die "$gpu is out of stock; pick another (./cloudgpu.sh offers)"
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
  [[ $status == running ]] || die "instance $id isn't running after 20 minutes (./cloudgpu.sh down)"
  if [[ ! -s $STATE/ssh_config ]] || ! ssh_cmd -o BatchMode=yes -o ConnectTimeout=15 true 2>/dev/null; then
    (umask 077; jq -r .ssh.password <<< "$inst" > "$STATE/password")
    write_ssh_config "$(jq -r .ssh.host <<< "$inst")" "$(jq -r .ssh.port <<< "$inst")" "$(jq -r '.ssh.user // "root"' <<< "$inst")"
    install_key
  fi
  ssh_ready
  ssh_cmd 'nvidia-smi --query-gpu=name,memory.total --format=csv,noheader' || die "the instance has no working GPU (./cloudgpu.sh down)"
  ssh_cmd "echo $(jq -r '.limits.expires_at // empty' <<< "$inst") > $DEADLINE_FILE"
  provision "$models"
  say "Ready: ./cloudgpu.sh connect (and ./cloudgpu.sh down when you're done)"
}

cmd_connect() {
  [[ -n $(instance_id) && -s $STATE/ssh_config ]] || die "nothing rented (./cloudgpu.sh up)"
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

# Read in full before running (bash otherwise reads a script as it goes), so editing this file or a git pull
# while it runs can't make it run something else; it ends with exit for the same reason.
{
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
exit
}
