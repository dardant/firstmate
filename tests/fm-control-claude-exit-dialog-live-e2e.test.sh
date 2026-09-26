#!/usr/bin/env bash
# Live guard for the Claude exit confirmation answer in bin/fm-control.sh
# (live-harness-optin family).
#
# When `/exit` reaches a Claude worker that is running a background shell,
# Claude renders "Background work is running" and waits for a choice instead of
# exiting, so an exit or relaunch that only waited for the agent to stop gave up
# with the old agent still running. bin/fm-control-lib.sh's
# fm_control_exit_confirmation_key recognizes that dialog from its rendered
# text, which is a vendor surface, so per .agents/skills/firstmate-coding-guidelines
# "Harness-dependent checks" it is proven here against the REAL installed
# Claude rather than only against the stub in tests/fm-control.test.sh.
#
# In a private, named Herdr lab session (never the default one; see
# tests/herdr-test-safety.sh), this launches a real Claude worker through
# fm-spawn, has it start a background shell (a uniquely timed `sleep`), and then:
#   1. submits `/exit` itself, requires the real viewport to be recognized as
#      the answerable dialog, and backs out with Escape (Claude's own cancel);
#   2. runs `fm-control relaunch`, which must answer the dialog, stop that
#      background shell, and bring up a replacement agent;
#   3. waits for the replacement's own background shell and runs
#      `fm-control exit`, which must answer the dialog again and stop the agent.
# After each stop it requires the exact background process to be gone and an
# uncommitted file in the worktree to be untouched.
#
# This submits prompts, so it spends model tokens and is opt-in: run it with
# FM_CONTROL_CLAUDE_EXIT_DIALOG_LIVE=1 after a Claude Code upgrade, and refresh
# docs/verification/runtime-backends.md ("Claude exit confirmation dialog")
# from its output.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

note() { printf '# %s\n' "$1"; }
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

fm_live_gate opt-in FM_CONTROL_CLAUDE_EXIT_DIALOG_LIVE herdr jq claude git

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION="fm-lab-claude-exit-$$"
SCRATCH=
cleanup_all() {
  # The spawn leaves a read-only git-hooks directory under the fixture state.
  [ -z "$SCRATCH" ] || fm_test_remove_tree "$SCRATCH"
  herdr_safe_stop_and_delete "$SESSION"
  [ -z "$SCRATCH" ] || [ ! -e "$SCRATCH" ] \
    || fail "the fixture scratch directory was left behind: $SCRATCH"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare the isolated Herdr lab session"
export HERDR_SESSION="$SESSION"

CLAUDE_VERSION=$(claude --version 2>&1 | head -1)
HERDR_VERSION=$(herdr --version 2>&1 | head -1)
note "live claude version: $CLAUDE_VERSION; $HERDR_VERSION"
vfail() { fail "$1 [claude $CLAUDE_VERSION]"; }

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-claude-exit.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)
HOME_DIR="$SCRATCH/home"
SLEEP_SECS=$((900 + $$ % 97))
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/cexit"
cat > "$HOME_DIR/data/cexit/brief.md" <<EOF
# Task
## Captain's intent
Live guard fixture for exit handling.

## Firstmate spec
Use your Bash tool with run_in_background set to true to run exactly: sleep $SLEEP_SECS
Then reply with the single word READY and stop. Do nothing else.
EOF

PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b cexit "$WT"
printf 'uncommitted work\n' > "$WT/unlanded.txt"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT" launcher-home "$SESSION") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-cexit" "$WT" "$SEEDED_TAB_ID") \
  || fail "create_task failed"
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
[ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] || fail "create_task did not return tab/pane ids"
TARGET="$SESSION:$PANE_ID"
{
  echo "window=$TARGET"
  echo "endpoint_task_id=cexit"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=low"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
} > "$HOME_DIR/state/cexit.meta"

run_fm() {  # <script> <args...>
  local script=$1
  shift
  env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/$script" "$@" 2>&1
}

viewport() {
  fm_backend_visible_capture herdr "$TARGET" 2>/dev/null
}

sleep_pids() {
  pgrep -x -f "sleep $SLEEP_SECS" 2>/dev/null | sort
}

# wait_background_shell <known-pids>: wait until the agent is running a
# background shell that is not one of <known-pids> and has reported READY.
# Prints the new pid.
wait_background_shell() {  # <known-pids>
  local known=$1 pid
  for _ in $(seq 1 120); do
    for pid in $(sleep_pids); do
      case " $known " in *" $pid "*) continue ;; esac
      if viewport | grep -qE '^. READY[[:space:]]*$'; then
        printf '%s' "$pid"
        return 0
      fi
    done
    sleep 2
  done
  return 1
}

require_stopped_shell() {  # <pid> <what>
  local pid=$1 what=$2
  for _ in $(seq 1 20); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.25
  done
  vfail "$what: the background shell (pid $pid) is still running after the agent stopped"
}

require_worktree_intact() {  # <what>
  [ "$(cat "$WT/unlanded.txt" 2>/dev/null)" = 'uncommitted work' ] \
    || fail "$1: the uncommitted file in the worktree did not survive"
}

OUT=$(run_fm fm-spawn.sh cexit --relaunch --harness claude --effort low) \
  || fail "could not launch the real Claude worker: $OUT"
FIRST_PID=$(wait_background_shell '') \
  || vfail "the real Claude worker never started its background shell and reported READY: $(viewport | tail -20)"
note "first worker started background shell pid $FIRST_PID"

# 1. The real dialog, read the production way, is the answerable shape.
fm_backend_herdr_send_text_line "$TARGET" "/exit" || fail "could not submit /exit to the lab worker"
SCREEN=
for _ in $(seq 1 40); do
  SCREEN=$(viewport)
  printf '%s\n' "$SCREEN" | grep -q 'Background work is running' && break
  sleep 0.25
done
KEY=$(printf '%s\n' "$SCREEN" | fm_control_exit_confirmation_key claude) \
  || vfail "the real viewport after /exit with a background shell was not recognized as the answerable exit dialog:
$SCREEN"
[ "$KEY" = Enter ] || vfail "the real exit dialog should be answered with Enter, got '$KEY'"
fm_backend_send_key herdr "$TARGET" Escape || fail "could not back out of the real exit dialog"
for _ in $(seq 1 20); do
  viewport | grep -q 'Background work is running' || break
  sleep 0.25
done
[ "$(fm_backend_agent_state herdr "$TARGET")" = alive ] \
  || vfail "Escape on the exit dialog should leave the agent running"
kill -0 "$FIRST_PID" 2>/dev/null || vfail "Escape on the exit dialog should leave the background shell running"
pass "real claude: /exit with a background shell renders the dialog the control plane recognizes and answers"

# 2. relaunch answers the dialog, stops the shell, and brings up a replacement.
OUT=$(run_fm fm-control.sh cexit relaunch --note "live guard relaunch through the exit dialog") \
  || vfail "relaunch through the background-work exit dialog failed: $OUT"
case "$OUT" in
  *"exits and stops those background tasks"*"relaunched cexit harness=claude"*) : ;;
  *) vfail "relaunch should report answering the exit dialog and the relaunch, got: $OUT" ;;
esac
require_stopped_shell "$FIRST_PID" relaunch
require_worktree_intact relaunch
pass "real claude: relaunch answers the background-work exit dialog and replaces the agent"

# 3. exit on the replacement answers the dialog again and stops the agent.
SECOND_PID=$(wait_background_shell "$FIRST_PID") \
  || vfail "the replacement Claude worker never started its background shell and reported READY: $(viewport | tail -20)"
note "replacement worker started background shell pid $SECOND_PID"
OUT=$(run_fm fm-control.sh cexit exit) \
  || vfail "exit through the background-work exit dialog failed: $OUT"
case "$OUT" in
  *"exits and stops those background tasks"*"stopped cexit harness=claude"*) : ;;
  *) vfail "exit should report answering the exit dialog and the stop, got: $OUT" ;;
esac
[ "$(fm_backend_agent_state herdr "$TARGET")" = dead ] || vfail "the agent should read stopped after exit"
require_stopped_shell "$SECOND_PID" exit
require_worktree_intact exit
pass "real claude: exit answers the background-work exit dialog and stops the agent and its background shell"

note "verified against claude $CLAUDE_VERSION through $HERDR_VERSION"
cleanup_all
trap - EXIT
