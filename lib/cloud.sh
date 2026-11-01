# Shared by the cloud GPU scripts (runpod.sh, cloudgpu.sh): set up this project on a rented machine over SSH.
# The including script sets PROJECT_DIR, STATE (with ssh_config in it), HOST_ALIAS, REPO_URL and REMOTE_DIR, and
# defines die and say.

ssh_cmd() { ssh -F "$STATE/ssh_config" "$HOST_ALIAS" "$@"; }
ssh_ready() {  # wait for a working (shared) connection, which later ssh_cmd calls then reuse
  for _ in $(seq 1 30); do ssh_cmd -o BatchMode=yes -o ConnectTimeout=15 true 2>/dev/null && return; sleep 10; done
  die "can't connect to the rented machine over SSH"
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

# Downloads the models listed on stdin (directory, name, URL; tab-separated) into ComfyUI/models/, three at a
# time, skipping files already there. Per file it leaves NAME.size (expected bytes) and NAME.ok or NAME.err in
# the status directory, and NAME.part in the models folder while downloading.
FETCH_MODELS='
set -uo pipefail
models="$1" status="$2"
rm -rf "$status" && mkdir -p "$status"
fetch() {
  local dir="$1" name="$2" url="$3" dest="$models/$1/$2"
  if find -L "$models" -name "$name" -size +0 2>/dev/null | grep -q .; then touch "$status/$name.ok"; return; fi
  mkdir -p "$models/$dir"
  # Headers along the redirects: the last status line says whether the file is there, x-linked-size (Hugging
  # Face) or the last content-length how big it is
  local head; head="$(curl -sIL --max-time 60 "$url" | tr -d "\r")"
  if [[ "$(awk "/^HTTP\// {c=\$2} END {print c}" <<< "$head")" != 200 ]]; then
    awk "/^HTTP\// {l=\$0} END {print \"HTTP: \" l}" <<< "$head" > "$status/$name.err"; return
  fi
  awk "tolower(\$1) ~ /^(x-linked-size|content-length):/ {s=\$2} END {print (s == \"\" ? 0 : s)}" <<< "$head" > "$status/$name.size"
  if curl -fsSL --retry 5 --retry-all-errors --connect-timeout 30 -C - -o "$dest.part" "$url" 2> "$status/$name.log"; then
    mv "$dest.part" "$dest" && touch "$status/$name.ok"
  else
    tail -1 "$status/$name.log" > "$status/$name.err"
  fi
}
while IFS=$'"'\t'"' read -r dir name url; do
  fetch "$dir" "$name" "$url" &
  while (( $(jobs -rp | wc -l) >= 3 )); do wait -n; done
done
wait
touch "$status/.done"
'

provision_project() {  # MODELS_JSON PREPARE_COMMAND: the project at this checkout's commit, ComfyUI running, models in
  local models="$1" prepare="$2" commit
  commit="$(git -C "$PROJECT_DIR" rev-parse HEAD)"
  git -C "$PROJECT_DIR" branch -r --contains "$commit" 2>/dev/null | grep -q . ||
    echo "warning: $commit isn't pushed; the rented machine runs the newest pushed commit instead"
  jq -e 'all(.[]; (.url | test("^https://([a-z0-9-]+\\.)*(huggingface\\.co|github\\.com|civitai\\.com)/")) and (.name | test("^[^/]+$")) and (.directory | test("^[a-z_]+$")))' \
    <<< "$models" >/dev/null || die "a workflow lists a model with an unexpected URL, name or folder"

  say "Fetching this project, then its models alongside setting it up"
  ssh_cmd "bash -s" <<EOF
set -euo pipefail
$prepare
[[ -d $REMOTE_DIR/.git ]] || git clone -q "$REPO_URL" $REMOTE_DIR
cd $REMOTE_DIR
git fetch -q origin && { git checkout -q "$commit" 2>/dev/null || git checkout -q origin/main; }
git submodule update -q --init ComfyUI
EOF
  local count; count="$(jq length <<< "$models")"
  if (( count )); then
    jq -r '.[] | "  \(.directory)/\(.name)"' <<< "$models"
    jq -r '.[] | [.directory, .name, .url] | @tsv' <<< "$models" |
      ssh_cmd "cat > /root/models.tsv && { setsid nohup bash -c $(printf %q "$FETCH_MODELS") fetch $REMOTE_DIR/ComfyUI/models /root/model-status < /root/models.tsv > /root/fetch-models.log 2>&1 & }"
  fi

  say "Setting up (the first time on a machine: PyTorch and ComfyUI, a few minutes)"
  ssh_cmd "bash -s" <<EOF
set -euo pipefail
cd $REMOTE_DIR
./setup.sh --no-service > setup.log 2>&1 || { tail -30 setup.log; exit 1; }
grep -E '^torch .* OK on' setup.log || true
.uv/bin/uv cache clean -q 2>/dev/null || true  # packages are in the venv; the download cache only takes space
# (an "a || b &" would background a subshell holding this SSH session's output open, so the session never ends)
if ! pgrep -f "[m]ain.py --listen 127.0.0.1" >/dev/null; then setsid nohup ./run.sh > /root/comfyui.log 2>&1 < /dev/null & fi
for _ in \$(seq 1 150); do curl -s -o /dev/null http://127.0.0.1:8188/ && exit 0; sleep 2; done
tail -30 /root/comfyui.log; exit 1
EOF

  (( count )) || return 0
  say "Models"
  local report
  while :; do  # files done, failed, bytes so far, bytes expected, finished, still running
    sleep 15
    report="$(ssh_cmd "cd /root/model-status 2>/dev/null || { echo 0 0 0 0 0 0; exit; }
      ok=\$(ls *.ok 2>/dev/null | wc -l) err=\$(ls *.err 2>/dev/null | wc -l)
      total=\$(cat *.size 2>/dev/null | awk '{s+=\$1} END {printf \"%.0f\\n\", s}')
      got=\$(for f in *.size; do n=\${f%.size}; [[ -e \$n.ok ]] && cat \"\$f\"; done 2>/dev/null | awk '{s+=\$1} END {printf \"%.0f\\n\", s}')
      part=\$(find $REMOTE_DIR/ComfyUI/models -name '*.part' -printf '%s\n' 2>/dev/null | awk '{s+=\$1} END {printf \"%.0f\\n\", s}')
      echo \$ok \$err \$((got + part)) \$total \$([[ -e .done ]] && echo 1 || echo 0) \$(pgrep -f '[f]etch $REMOTE_DIR/ComfyUI/models' >/dev/null && echo 1 || echo 0)")" ||
      continue  # a dropped connection: ask again
    read -r ok err got total finished running <<< "$report"
    awk -v ok="$ok" -v n="$count" -v got="$got" -v total="$total" -v err="$err" \
      'BEGIN {printf "  %d of %d files, %.1f of %.1f GB fetched%s\n", ok, n, got / 1e9, total / 1e9, err ? ", " err " failed" : ""}' 
    [[ $finished == 1 ]] && break
    [[ $running == 1 ]] || die "the model downloads stopped (see /root/fetch-models.log there: $0 ssh cat /root/fetch-models.log)"
  done
  if (( err )); then
    die "$(ssh_cmd 'cd /root/model-status && for f in *.err; do echo "${f%.err}: $(cat "$f")"; done')"
  fi
}
