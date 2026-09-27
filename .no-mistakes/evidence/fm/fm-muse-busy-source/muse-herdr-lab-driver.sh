#!/usr/bin/env bash
# Live driver: a real Muse 1.4.0 worker spawned through the real bin/fm-spawn.sh
# into an isolated fm-lab-* Herdr session, then classified, steered, and torn.
# Usage: muse-herdr-lab-driver.sh <repo-root> <base-bin-dir> <evidence-dir>
set -u
ROOT=$1 BASEBIN=$2 EV=$3
LOG="$EV/muse-herdr-lab-transcript.txt"
: > "$LOG"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-muse-lab.XXXXXX")
LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
LAB=$("$LAB_HELPER" name muse-busy) || exit 1
export HERDR_SESSION="$LAB"
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_ENV HERDR_SOCKET_PATH TMUX TMUX_PANE
export TREEHOUSE_ROOT="$TMP_ROOT/treehouse"
export COLORTERM=truecolor
# The steer is aimed at this scratch lab worker only, as the doorbell live guard does.
unset NO_MISTAKES_GATE
PROJECT="$TMP_ROOT/project"
HOME_DIR="$TMP_ROOT/home"
ID=musebusy
WT=
cleanup() {
  [ -n "$WT" ] && (cd "$PROJECT" && treehouse return --force "$WT") >/dev/null 2>&1
  "$LAB_HELPER" teardown "$LAB"; say "teardown exit=$?"
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT
trap 'exit 130' TERM INT

say "lab session: $LAB"
"$LAB_HELPER" provision "$LAB" || { say "provision failed"; exit 1; }

mkdir -p "$PROJECT" "$HOME_DIR/state" "$HOME_DIR/data/$ID" "$HOME_DIR/config"
git -C "$PROJECT" init -q
printf '# scratch\n' > "$PROJECT/README.md"
git -C "$PROJECT" add README.md
git -C "$PROJECT" -c user.name=t -c user.email=t@example.invalid commit -qm initial
git clone --quiet --bare "$PROJECT" "$PROJECT.origin.git"
git -C "$PROJECT" remote add origin "file://$PROJECT.origin.git"
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
cat > "$HOME_DIR/data/$ID/brief.md" <<'EOF'
# Task
## Captain's intent
Scratch lab task used to observe Firstmate's busy signal on Muse.

## Firstmate spec
Run exactly one shell command, `sleep 100`, in the FOREGROUND (not backgrounded) as a single tool call. When it finishes, reply with the single word "slept" and stop. Do not do anything else, do not edit files, do not commit.
EOF

say "== spawn (fm-spawn.sh --harness muse --backend herdr)"
FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJECT" --mode local-only --yolo on --harness muse --backend herdr \
  > "$TMP_ROOT/spawn.out" 2> "$TMP_ROOT/spawn.err"
rc=$?
tail -5 "$TMP_ROOT/spawn.out" | tee -a "$LOG"
[ "$rc" = 0 ] || { say "spawn failed rc=$rc"; cat "$TMP_ROOT/spawn.err" | tee -a "$LOG"; exit 1; }
WT=$(sed -n 's/^worktree=//p' "$HOME_DIR/state/$ID.meta" | tail -1)
PANE=$(sed -n 's/^herdr_pane_id=//p' "$HOME_DIR/state/$ID.meta" | tail -1)
TARGET="$LAB:$PANE"
say "worktree=$WT pane=$PANE"
say "binding: $(tr '\n' ' ' < "$HOME_DIR/state/$ID.muse-session")"

classify() {  # <bin-dir>
  (
    export FM_HOME="$HOME_DIR"
    . "$ROOT/bin/fm-backend.sh"; fm_backend_source herdr >/dev/null 2>&1
    . "$1/fm-busy-lib.sh"
    fm_busy_classify herdr "$TARGET" muse "$ID" "$HOME_DIR/state" ""
  ) 2>/dev/null
}
crew_state() {
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_CREW_STATE_NO_FORGE=1 "$ROOT/bin/fm-crew-state.sh" "$ID" 2>&1 | head -1
}
native() { "$LAB_HELPER" run "$LAB" agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // "none"'; }
session_log() { ( . "$ROOT/bin/fm-busy-lib.sh"; fm_busy_muse_session_log "$HOME_DIR/state" "$ID" ) 2>/dev/null; }
composer() { ( export FM_HOME="$HOME_DIR"; . "$ROOT/bin/fm-backend.sh"; fm_backend_source herdr >/dev/null 2>&1; fm_backend_composer_state herdr "$TARGET" ) 2>/dev/null; }

say "== busy/idle through a 100s foreground tool call (HEAD vs base classifier)"
saw_busy_log=0 saw_idle_after=0
for i in $(seq 1 60); do
  h=$(classify "$ROOT/bin"); b=$(classify "$BASEBIN"); n=$(native); c=$(crew_state)
  say "t+$((i*5))s native=$n head='$h' base='$b' crew-state='$c'"
  case "$h" in "busy muse-session-log") saw_busy_log=1 ;; esac
  if [ "$saw_busy_log" = 1 ] && [ "$h" = "idle muse-session-log" ]; then saw_idle_after=1; break; fi
  sleep 5
done
say "RESULT busy-during-tool-call=$saw_busy_log idle-after-turn=$saw_idle_after"
SL=$(session_log); say "session log: $SL"
# (raw session.jsonl copies were removed from published evidence)
say "first line kind: $(head -c 80 "$SL")"

say "== pane after turn 1"
"$LAB_HELPER" run "$LAB" pane read "$PANE" --lines 25 2>/dev/null | tee "$EV/muse-pane-after-turn1.txt" | tail -12 | tee -a "$LOG"

say "== adversarial: append a torn complete line to the live session.jsonl, then steer"
printf '{"payload_type":"runtime.session","payload":{"kind":"run","run_id":"torn\n' >> "$SL"
say "after torn line: head='$(classify "$ROOT/bin")' fold=$( . "$ROOT/bin/fm-busy-lib.sh"; fm_busy_muse_run_state "$SL")"

say "== steer mid-turn with fm-send.sh (doorbell), turn 2 starts a sleep then three more steers"
FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-send.sh" "$ID" \
  'Run `sleep 45` in the foreground as one tool call, then reply "slept2".' 2>&1 | tee -a "$LOG"
saw_busy2=0
for i in $(seq 1 12); do
  sleep 2
  h=$(classify "$ROOT/bin")
  say "steer1 t+$((i*2))s head='$h' composer=$(composer)"
  [ "$h" = "busy muse-session-log" ] && { saw_busy2=1; break; }
done
for k in 2 3 4; do
  FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-send.sh" "$ID" \
    "Create the file steer-$k.txt in your worktree containing the word ok. No reply needed." 2>&1 | tee -a "$LOG"
  sleep 2
  say "after steer $k: composer=$(composer) head='$(classify "$ROOT/bin")'"
done
say "RESULT busy-after-torn-line=$saw_busy2"
saw_idle2=0
for i in $(seq 1 60); do
  h=$(classify "$ROOT/bin")
  pending=$(ls "$HOME_DIR/state/inbox/$ID" 2>/dev/null | grep -vc handled)
  say "drain t+$((i*5))s head='$h' composer=$(composer) files=$(ls "$WT" | grep -c '^steer-')"
  if [ "$h" = "idle muse-session-log" ] && [ "$(ls "$WT" | grep -c '^steer-')" = 3 ]; then saw_idle2=1; break; fi
  sleep 5
done
say "RESULT idle-after-steers=$saw_idle2 steer-files=$(ls "$WT" | grep '^steer-' | tr '\n' ' ')"
say "inbox tree:"; find "$HOME_DIR/state" -path "*inbox*" -type f 2>/dev/null | sed "s|$HOME_DIR|\$FM_HOME|" | tee -a "$LOG"
say "fold events tail:"; node "$ROOT/bin/fm-muse-session.cjs" events "$SL" | tail -8 | tee -a "$LOG"
say "torn line present in log: $(grep -c '"run_id":"torn$' "$SL")"
# (raw session.jsonl copies were removed from published evidence)
"$LAB_HELPER" run "$LAB" pane read "$PANE" --format ansi --lines 40 2>/dev/null > "$EV/muse-pane-final.txt"
say "final crew-state: $(crew_state)"
