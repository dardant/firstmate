#!/usr/bin/env bash
# Adversarial/baseline live scenarios for the Claude exit-dialog fix, run in a
# private fm-lab- Herdr session (modeled on tests/fm-control-claude-exit-dialog-live-e2e.test.sh).
#   A. baseline: the PRE-FIX fm-control.sh (base 5391df4) wedges: exit=unconfirmed, agent alive.
#   B. pointer moved to "2. Move to background and exit" while the FIXED exit waits:
#      control plane must not answer, must end exit=unconfirmed exit-dialog=none, agent+shell alive,
#      dialog still on screen untouched.
#   C. no background work: fixed exit on a plain idle Claude worker still stops it normally.
set -u
ROOT=${ROOT:?}
BASE_REV=${BASE_REV:?}
. "$ROOT/tests/lib.sh"
note() { printf '# %s\n' "$1"; }
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; exit 1; }
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
SESSION="fm-lab-cexit-adv-$$"
SCRATCH=
cleanup_all() { [ -z "$SCRATCH" ] || rm -rf -- "$SCRATCH"; herdr_safe_stop_and_delete "$SESSION"; }
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "prepare lab"
export HERDR_SESSION="$SESSION"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-cexit-adv.XXXXXX"); SCRATCH=$(cd "$SCRATCH" && pwd)
BASE="$SCRATCH/base"; mkdir -p "$BASE"
git -C "$ROOT" archive "$BASE_REV" | tar -x -C "$BASE"
HOME_DIR="$SCRATCH/home"; SLEEP_SECS=$((1000 + $$ % 97))
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/cexit"
write_brief() {  # <with-bg 0|1>
  if [ "$1" = 1 ]; then
    cat > "$HOME_DIR/data/cexit/brief.md" <<EOF
# Task
## Captain's intent
Live guard fixture for exit handling.

## Firstmate spec
Use your Bash tool with run_in_background set to true to run exactly: sleep $SLEEP_SECS
Then reply with the single word READY and stop. Do nothing else.
EOF
  else
    cat > "$HOME_DIR/data/cexit/brief.md" <<EOF
# Task
## Captain's intent
Live guard fixture for exit handling.

## Firstmate spec
Reply with the single word READY and stop. Do not run any tools.
EOF
  fi
}
write_brief 1
PROJ="$SCRATCH/proj"; WT="$SCRATCH/wt"; mkdir -p "$PROJ"
git -C "$PROJ" init -q; printf '# proj\n' > "$PROJ/README.md"; git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name=T -c user.email=t@example.invalid commit -qm initial
git -C "$PROJ" worktree add --quiet -b cexit "$WT"
printf 'uncommitted work\n' > "$WT/unlanded.txt"
. "$ROOT/bin/fm-backend.sh"; . "$ROOT/bin/fm-control-lib.sh"
fm_backend_source herdr || fail "source herdr"
CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT" launcher-home "$SESSION") || fail container
CONTAINER=${CONTAINER_RAW%%$'\t'*}; SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}; WORKSPACE_ID=${CONTAINER#*:}
read -r TAB_ID PANE_ID <<EOF
$(fm_backend_herdr_create_task "$CONTAINER" "fm-cexit" "$WT" "$SEEDED_TAB_ID")
EOF
TARGET="$SESSION:$PANE_ID"
{ echo "window=$TARGET"; echo "endpoint_task_id=cexit"; echo "worktree=$WT"; echo "project=$PROJ"
  echo "harness=claude"; echo "kind=ship"; echo "mode=no-mistakes"; echo "yolo=off"; echo "model=default"
  echo "effort=low"; echo "backend=herdr"; echo "herdr_session=$SESSION"; echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TAB_ID"; echo "herdr_pane_id=$PANE_ID"; } > "$HOME_DIR/state/cexit.meta"
run_fm() { local root=$1 script=$2; shift 2
  env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 "$root/bin/$script" "$@" 2>&1; }
viewport() { fm_backend_visible_capture herdr "$TARGET" 2>/dev/null; }
sleep_pids() { pgrep -x -f "sleep $SLEEP_SECS" 2>/dev/null | sort; }
wait_ready() {  # <need-bg 0|1>
  for _ in $(seq 1 120); do
    if viewport | grep -qE '^. READY[[:space:]]*$'; then
      if [ "$1" = 0 ] || [ -n "$(sleep_pids)" ]; then return 0; fi
    fi
    sleep 2
  done; return 1; }
show() { printf -- '--- viewport (%s) ---\n' "$1"; viewport | sed -e '/^[[:space:]]*$/d' | tail -n 16; printf -- '--- end viewport ---\n'; }

OUT=$(run_fm "$ROOT" fm-spawn.sh cexit --relaunch --harness claude --effort low) || fail "spawn: $OUT"
wait_ready 1 || fail "worker never READY with bg shell: $(viewport | tail -20)"
PID1=$(sleep_pids | head -1); note "worker background shell pid $PID1"

# A. baseline: pre-fix fm-control exit wedges on the dialog.
note "A: running PRE-FIX ($BASE_REV) fm-control.sh cexit exit with FM_CONTROL_EXIT_WAIT=15"
OUT=$(FM_CONTROL_EXIT_WAIT=15 run_fm "$BASE" fm-control.sh cexit exit); RC=$?
printf 'pre-fix exit rc=%s output:\n%s\n' "$RC" "$OUT"
show "after pre-fix exit"
[ "$RC" != 0 ] || fail "A: pre-fix exit unexpectedly succeeded"
case "$OUT" in *exit=unconfirmed*) : ;; *) fail "A: pre-fix exit did not report exit=unconfirmed" ;; esac
[ "$(fm_backend_agent_state herdr "$TARGET")" = alive ] || fail "A: agent should still be alive"
viewport | grep -q 'Background work is running' || fail "A: dialog should be showing"
pass "baseline reproduced: pre-fix exit wedges on 'Background work is running' with exit=unconfirmed and the agent alive"
fm_backend_send_key herdr "$TARGET" Escape
for _ in $(seq 1 20); do viewport | grep -q 'Background work is running' || break; sleep 0.25; done
kill -0 "$PID1" 2>/dev/null || fail "A: bg shell died after Escape"

# B. pointer moved off choice 1 while the fixed exit waits.
note "B: running FIXED fm-control.sh cexit exit (FM_CONTROL_POLL=3 FM_CONTROL_EXIT_WAIT=12) and moving the pointer to choice 2 as soon as the dialog renders"
OUTF="$SCRATCH/b.out"
( FM_CONTROL_POLL=3 FM_CONTROL_EXIT_WAIT=12 run_fm "$ROOT" fm-control.sh cexit exit > "$OUTF"; echo "rc=$?" >> "$OUTF" ) &
BG=$!
moved=0
for _ in $(seq 1 300); do
  if viewport | grep -q 'Background work is running'; then
    herdr pane send-keys "$PANE_ID" down --session "$SESSION" >/dev/null 2>&1 && moved=1
    break
  fi
  sleep 0.05
done
[ "$moved" = 1 ] || fail "B: never saw the dialog to move the pointer"
sleep 0.5; show "B: pointer moved, fm-control still waiting"
wait "$BG"
OUT=$(cat "$OUTF"); printf 'fixed exit output:\n%s\n' "$OUT"
show "B: after fixed exit gave up"
case "$OUT" in *"answered with the choice"*) fail "B: race lost - control plane answered before the pointer moved (re-run)";; esac
case "$OUT" in *rc=0*) fail "B: exit claimed success" ;; esac
case "$OUT" in *"exit=unconfirmed exit-dialog=none"*) : ;; *) fail "B: expected exit=unconfirmed exit-dialog=none" ;; esac
[ "$(fm_backend_agent_state herdr "$TARGET")" = alive ] || fail "B: agent should still be alive"
kill -0 "$PID1" 2>/dev/null || fail "B: bg shell should still be running"
viewport | grep -qE '❯[[:space:]]*2\.[[:space:]]+Move to background and exit' || fail "B: dialog should still be on screen with pointer on choice 2 (no key sent)"
[ "$(cat "$WT/unlanded.txt")" = 'uncommitted work' ] || fail "B: worktree changed"
pass "adversarial: a dialog with the pointer moved off '1. Exit and stop tasks' is not answered; exit ends exit=unconfirmed exit-dialog=none with agent and background shell still running"
fm_backend_send_key herdr "$TARGET" Escape
for _ in $(seq 1 20); do viewport | grep -q 'Background work is running' || break; sleep 0.25; done

# C. no background work: plain exit still works.
note "C: relaunch onto a brief with no background work, then fixed exit"
write_brief 0
OUT=$(run_fm "$ROOT" fm-control.sh cexit relaunch --note "adv: plain relaunch"); RC=$?
printf 'fixed relaunch rc=%s output:\n%s\n' "$RC" "$OUT"
[ "$RC" = 0 ] || fail "C: relaunch failed"
case "$OUT" in *"answered with the choice"*) : ;; *) fail "C: relaunch should have answered the dialog from the old worker's shell" ;; esac
for _ in $(seq 1 20); do kill -0 "$PID1" 2>/dev/null || break; sleep 0.25; done
kill -0 "$PID1" 2>/dev/null && fail "C: old bg shell survived relaunch"
wait_ready 0 || fail "C: plain worker never READY"
[ -z "$(sleep_pids)" ] || fail "C: unexpected bg shell"
OUT=$(run_fm "$ROOT" fm-control.sh cexit exit); RC=$?
printf 'fixed plain exit rc=%s output:\n%s\n' "$RC" "$OUT"
[ "$RC" = 0 ] || fail "C: plain exit failed"
case "$OUT" in *"answered with the choice"*) fail "C: no dialog should have been answered" ;; esac
case "$OUT" in *"stopped cexit"*) : ;; *) fail "C: expected stopped" ;; esac
[ "$(fm_backend_agent_state herdr "$TARGET")" = dead ] || fail "C: agent should be dead"
[ "$(cat "$WT/unlanded.txt")" = 'uncommitted work' ] || fail "C: worktree changed"
pass "regression: exit on a Claude worker without background work stops it with no dialog handling"
cleanup_all; trap - EXIT
