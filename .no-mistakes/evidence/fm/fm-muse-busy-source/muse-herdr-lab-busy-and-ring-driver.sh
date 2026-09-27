#!/usr/bin/env bash
# Throwaway Herdr lab driver: real Muse 1.4.0 in a named fm-lab-* session.
# Usage: fm-muse-lab-driver.sh <evidence-dir>
set -u
HEAD_ROOT=/home/dardan/.no-mistakes/worktrees/a2097c65a770/01M3HMGP1EC0XNY8KE6H4EXV42
BASE_ROOT=/tmp/fm-base-665e
LAB_HELPER=$HEAD_ROOT/bin/fm-herdr-lab.sh
E=$1
ORIGINAL_PATH=$PATH
unset HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH TMUX
SCRATCH=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-muse-lab.XXXXXX")
mkdir -p "$SCRATCH/ws" "$SCRATCH/data" "$SCRATCH/fake" "$SCRATCH/state"
git -C "$SCRATCH/ws" init -q
WS=$(cd "$SCRATCH/ws" && pwd -P)
SESSION=$("$LAB_HELPER" name muse-ring) || exit 1
log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }

cleanup() {
  trap - EXIT
  PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION" && log "lab $SESSION torn down" || log "TEARDOWN FAILED for $SESSION"
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

# Herdr wrapper: every call goes through the lab helper. With COALESCE_DIR set,
# a doorbell `pane send-text` is held and flushed together with the next
# `pane send-keys ... enter` as ONE send-text carrying a trailing CR, which is
# exactly the coalesced text+Enter read that Muse 1.4.0 drops.
cat > "$SCRATCH/fake/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
fi
run() { exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\$@"; }
if [ -n "\${COALESCE_DIR:-}" ] && [ "\${args[0]:-} \${args[1]:-}" = "pane send-text" ] \
  && [[ "\${args[3]:-}" == ": Firstmate instruction waiting"* ]]; then
  printf '%s' "\${args[3]}" > "\$COALESCE_DIR/held"
  echo "held send-text" >> "\$COALESCE_DIR/trace"
  exit 0
fi
if [ -n "\${COALESCE_DIR:-}" ] && [ -f "\$COALESCE_DIR/held" ] && [ "\${args[0]:-} \${args[1]:-}" = "pane send-keys" ]; then
  last=\${args[\$((\${#args[@]}-1))]}
  case "\$last" in [Ee]nter)
    text=\$(cat "\$COALESCE_DIR/held"); rm -f "\$COALESCE_DIR/held"
    echo "coalesced text+CR into one send-text" >> "\$COALESCE_DIR/trace"
    run pane send-text "\${args[2]}" "\$text"\$'\r'
  ;; esac
fi
[ "\${args[0]:-} \${args[1]:-}" = "pane send-keys" ] && [ -n "\${COALESCE_DIR:-}" ] && echo "enter" >> "\$COALESCE_DIR/trace"
run "\${args[@]}"
EOF
chmod +x "$SCRATCH/fake/herdr"

"$LAB_HELPER" provision "$SESSION" || exit 1
log "provisioned $SESSION"
lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
export PATH="$SCRATCH/fake:$ORIGINAL_PATH" HERDR_SESSION="$SESSION"

WS_JSON=$(lab workspace create --cwd "$WS" --label fm-muse-lab --no-focus) || exit 1
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') || exit 1
TARGET="$SESSION:$PANE"
log "pane $TARGET"
lab pane send-text "$PANE" "env COLORTERM=truecolor XDG_DATA_HOME=$SCRATCH/data MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on muse --yolo --reasoning-effort low" >/dev/null
lab pane send-keys "$PANE" enter >/dev/null
printf 'sessions_root=%s\nworkspace_root=%s\n' "$SCRATCH/data/muse/sessions" "$WS" > "$SCRATCH/state/t1.muse-session"

classify() {  # <root> -> "<fm_busy_classify herdr> | <log-only fold>"
  (
    . "$1/bin/fm-backend.sh"
    . "$1/bin/fm-busy-lib.sh"
    a=$(fm_busy_classify herdr "$TARGET" muse t1 "$SCRATCH/state" 2>/dev/null)
    b=$(fm_busy_classify tmux fake:0 muse t1 "$SCRATCH/state" 2>/dev/null)
    printf 'herdr-path=[%s] session-log-path=[%s]' "$a" "$b"
  )
}
both() {  # <label>
  rm -f "$SCRATCH/state/t1.muse-session-current"
  log "$1 BASE(665e0e8b): $(classify "$BASE_ROOT")"
  rm -f "$SCRATCH/state/t1.muse-session-current"
  log "$1 HEAD(8ed03146): $(classify "$HEAD_ROOT")"
  log "$1 herdr native: $(lab pane get "$PANE" 2>/dev/null | jq -c '.result.pane | {agent, agent_status}' 2>/dev/null)"
}
composer() {  # <root>
  ( . "$1/bin/fm-backend.sh"; fm_backend_composer_state herdr "$TARGET" 2>/dev/null )
}
snap() {  # <name>
  lab pane read "$PANE" --source visible --format text 2>/dev/null | sed -e 's/[[:space:]]*$//' | awk 'NF{p=NR} {l[NR]=$0} END{for(i=1;i<=p;i++) print l[i]}' | tail -25 > "$E/$1.txt"; true
}

for _ in $(seq 1 120); do [ "$(composer "$HEAD_ROOT")" = empty ] && break; sleep 0.5; done
sleep 3
log "composer after launch: $(composer "$HEAD_ROOT")"
snap ring-lab-before-ring
# 4. doorbell ring with coalesced text+Enter (Muse drops the CR)
ring() {  # <root> <tag>
  local st="$SCRATCH/inbox-$2" rec rc=0
  mkdir -p "$st" "$SCRATCH/co-$2"
  rec=$(FM_STATE_OVERRIDE="$st" bash -c '. "$1/bin/fm-task-inbox-lib.sh"; fm_task_inbox_write "$2" t1 "$3"' _ "$1" "$st" "reply with the word ack-$2")
  log "ring[$2] record: $rec"
  FM_STATE_OVERRIDE="$st" COALESCE_DIR="$SCRATCH/co-$2" bash -c '. "$1/bin/fm-task-inbox-lib.sh"; fm_task_inbox_ring herdr "$2" "$3"' _ "$1" "$TARGET" "$rec" || rc=$?
  log "ring[$2] rc=$rc trace: $(tr '\n' ',' < "$SCRATCH/co-$2/trace" 2>/dev/null)"
  sleep 3
  log "ring[$2] composer after ring: $(composer "$HEAD_ROOT")"
}
ring "$HEAD_ROOT" head
for _ in $(seq 1 90); do
  rm -f "$SCRATCH/state/t1.muse-session-current"
  case "$(classify "$HEAD_ROOT")" in *"session-log-path=[busy"*) log "head doorbell turn observed busy"; break ;; esac
  sleep 0.5
done
for _ in $(seq 1 120); do
  rm -f "$SCRATCH/state/t1.muse-session-current"
  case "$(classify "$HEAD_ROOT")" in *"session-log-path=[idle"*) break ;; esac
  sleep 1
done
snap ring-lab-head-ring-submitted
log "head inbox after turn: pending=[$(ls "$SCRATCH/inbox-head/t1.inbox" 2>/dev/null | grep msg | tr '\n' ' ')] handled=[$(ls "$SCRATCH/inbox-head/t1.inbox/handled" 2>/dev/null | tr '\n' ' ')]"
sleep 2
log "composer before base ring: $(composer "$HEAD_ROOT")"
ring "$BASE_ROOT" base
snap ring-lab-base-ring-stranded
st="$SCRATCH/inbox-base2"; mkdir -p "$st"
rec=$(FM_STATE_OVERRIDE="$st" bash -c '. "$1/bin/fm-task-inbox-lib.sh"; fm_task_inbox_write "$2" t1 second' _ "$BASE_ROOT" "$st")
rc=0; FM_STATE_OVERRIDE="$st" bash -c '. "$1/bin/fm-task-inbox-lib.sh"; fm_task_inbox_ring herdr "$2" "$3"' _ "$BASE_ROOT" "$TARGET" "$rec" || rc=$?
log "base second ring rc=$rc (1 = skipped on pending composer)"
node -e '
const fs=require("fs");
for (const l of fs.readFileSync(process.argv[1],"utf8").split("\n")) { if(!l) continue; let r; try{r=JSON.parse(l)}catch{continue}
 const p=r.payload; if(r.payload_type==="runtime.session"&&p?.kind==="run"&&p.event?.kind==="started") console.log("run started prompt:", JSON.stringify(String(p.event.prompt).slice(0,90))); }' "$(ls "$SCRATCH"/data/muse/sessions/*/*/*/*/session.jsonl | head -1)"
lab pane send-text "$PANE" "/exit" >/dev/null; lab pane send-keys "$PANE" enter >/dev/null; sleep 2
