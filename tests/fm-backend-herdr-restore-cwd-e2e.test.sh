#!/usr/bin/env bash
# tests/fm-backend-herdr-restore-cwd-e2e.test.sh - ISOLATED real-Herdr
# end-to-end test for WHERE a restarted Herdr server resumes a ship's agent.
#
# Herdr persists each pane with its root shell's working directory and, with
# `[session] resume_agents_on_restore` (default on), re-runs a resumable
# agent's resume command there after a server restart. A ship tab opened in the
# project and moved into its worktree by the interactive `treehouse get`
# subshell keeps its root shell in the project, so a restart resumed the worker
# in the primary checkout. bin/fm-spawn.sh now leases the worktree first and
# opens the tab inside it (spawn_treehouse_lease_worktree).
#
# This drives the REAL bin/fm-spawn.sh against a real Treehouse pool in an
# isolated lab, registers a Claude session reference on the task pane the way
# Herdr's own Claude integration does, restarts the lab server through the
# guarded helper, and requires that Herdr's resume runs in the recorded
# worktree, with a lab viewer attached the way the captain's terminal is. No
# model is called: the resumed `claude` is a stand-in on the lab server's PATH
# that records its working directory.
#
# Safety (tests/herdr-test-safety.sh): every Herdr call goes through
# bin/fm-herdr-lab.sh, which appends the named session flag and verifies the
# default fleet session is unchanged after teardown.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found (required by fm-spawn.sh)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (required by the lab viewer)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-restore-cwd.XXXXXX")
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-herdr-restore-cwd) || {
  rm -rf "$TMP_ROOT"
  printf 'not ok - could not generate an isolated Herdr lab session name\n' >&2
  exit 1
}
export HERDR_SESSION="$HERDR_LAB_SESSION" HERDR_LAB_HELPER HERDR_LAB_SESSION

# Keep the Treehouse pool inside the scratch root so teardown removes it with
# everything else instead of leaving a project pool under ~/.treehouse.
export TREEHOUSE_ROOT="$TMP_ROOT/treehouse"

FAKEBIN="$TMP_ROOT/fakebin"
AGENT_LOG="$TMP_ROOT/agent.log"
PROJECT_DIR="$TMP_ROOT/project"
HOME_DIR="$TMP_ROOT/home"
WORKTREES=()
CLEANED=0
cleanup_all() {
  local wt status=0
  [ "$CLEANED" = 0 ] || return 0
  CLEANED=1
  for wt in ${WORKTREES[@]+"${WORKTREES[@]}"}; do
    [ -n "$wt" ] && (cd "$PROJECT_DIR" 2>/dev/null && treehouse return --force "$wt") >/dev/null 2>&1
  done
  WORKTREES=()
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=$?
  rm -rf "$TMP_ROOT"
  return "$status"
}
trap cleanup_all EXIT

# A lab that outlives the test is a failure, not a pass: the EXIT trap alone
# would discard teardown's status.
finish_lab() {
  if ! cleanup_all; then
    trap - EXIT
    printf 'not ok - isolated Herdr lab teardown failed or the default fleet session changed\n' >&2
    exit 1
  fi
  trap - EXIT
  exit 0
}

# The stand-in agent. Launched by the spawn as `restore-standin`, it reports the
# same Claude session reference Herdr's integration hook reports, then idles.
# Resumed by Herdr as `claude --resume <id>`, it only records where it runs.
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/restore-standin" <<'SH'
#!/usr/bin/env bash
printf 'launch\t%s\n' "$(pwd -P)" >> "$AGENT_LOG"
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane report-agent "$HERDR_PANE_ID" \
  --source herdr:claude --agent claude --state idle >/dev/null 2>&1
if "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane report-agent-session "$HERDR_PANE_ID" \
  --source herdr:claude --agent claude --agent-session-id fm-restore-cwd-session >/dev/null 2>&1; then
  printf 'reported\n' >> "$AGENT_LOG"
else
  printf 'report-unsupported\n' >> "$AGENT_LOG"
fi
exec sleep 100000
SH
cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
printf 'resume\t%s\t%s\n' "$(pwd -P)" "$*" >> "$AGENT_LOG"
exec sleep 100000
SH
chmod +x "$FAKEBIN/restore-standin" "$FAKEBIN/claude"
: > "$AGENT_LOG"
export AGENT_LOG

# The lab server, and so every pane and every restored resume, inherits this
# PATH and a shell that sources no startup file that could reorder it.
export PATH="$FAKEBIN:$PATH" SHELL=/bin/sh
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail "could not provision isolated Herdr lab session"

mkdir -p "$PROJECT_DIR" "$HOME_DIR/state" "$HOME_DIR/data/restore1" "$HOME_DIR/config"
git -C "$PROJECT_DIR" init -q
printf '# scratch\n' > "$PROJECT_DIR/README.md"
git -C "$PROJECT_DIR" add README.md
git -C "$PROJECT_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git clone --quiet --bare "$PROJECT_DIR" "$PROJECT_DIR.origin.git"
git -C "$PROJECT_DIR" remote add origin "file://$PROJECT_DIR.origin.git"
PROJECT_REAL=$(cd "$PROJECT_DIR" && pwd -P)
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
cat > "$HOME_DIR/data/restore1/brief.md" <<'EOF'
# Task
## Captain's intent
Herdr restore working-directory fixture.

## Firstmate spec
Idle until the lab restarts.
EOF

FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" restore1 "$PROJECT_DIR" "sh -c 'exec restore-standin'" \
  --mode no-mistakes --yolo off --backend herdr > "$TMP_ROOT/spawn.out" 2> "$TMP_ROOT/spawn.err" \
  || fail "the herdr ship spawn failed: $(cat "$TMP_ROOT/spawn.err")"
WT=$(sed -n 's/^worktree=//p' "$HOME_DIR/state/restore1.meta" | tail -1)
[ -n "$WT" ] || fail "the spawn recorded no worktree"
WORKTREES+=("$WT")
WT_REAL=$(cd "$WT" && pwd -P)
PANE=$(sed -n 's/^herdr_pane_id=//p' "$HOME_DIR/state/restore1.meta" | tail -1)
[ -n "$PANE" ] || fail "the spawn recorded no herdr pane"

for _ in $(seq 1 100); do
  grep -q '^report' "$AGENT_LOG" && break
  sleep 0.1
done
grep -q "$(printf '^launch\t%s$' "$WT_REAL")" "$AGENT_LOG" \
  || fail "the stand-in agent did not start in the recorded worktree: $(cat "$AGENT_LOG")"
grep -q '^report' "$AGENT_LOG" || fail "the stand-in agent never reached its session report: $(cat "$AGENT_LOG")"
ROOT_CWD=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane get "$PANE" | jq -r '.result.pane.cwd // empty')
[ "$(cd "$ROOT_CWD" 2>/dev/null && pwd -P)" = "$WT_REAL" ] \
  || fail "the task pane's root directory is '$ROOT_CWD', not the worktree '$WT_REAL'; a restart would resume the agent there"
pass "real herdr: a ship's pane opens with its root shell in the leased worktree"

# Agent session references, and so resume on restore, arrived after the pinned
# CI release; an older Herdr has nothing to resume, which is named rather than
# passed over.
if ! grep -q '^reported$' "$AGENT_LOG"; then
  echo "# restore phase not exercised: $(herdr --version 2>/dev/null | head -1) rejects pane report-agent-session, so it resumes no agent on restart"
  finish_lab
fi

"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null || fail "could not stop the lab session"
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail "could not restart the lab session"
# Herdr 0.7.4 spawns restored panes, and so runs their resume, only once a
# client attaches, as the captain's own terminal does after a real restart.
"$HERDR_LAB_HELPER" viewer start "$HERDR_LAB_SESSION" >/dev/null \
  || fail "could not attach a foreground viewer to the restarted lab session"
for _ in $(seq 1 300); do
  grep -q '^resume' "$AGENT_LOG" && break
  sleep 0.1
done
RESUME=$(grep '^resume' "$AGENT_LOG" | head -1)
[ -n "$RESUME" ] || fail "Herdr did not resume the reported session after the restart (is resume_agents_on_restore off?): $(cat "$AGENT_LOG")"
RESUME_CWD=$(printf '%s' "$RESUME" | cut -f2)
[ "$RESUME_CWD" != "$PROJECT_REAL" ] \
  || fail "Herdr resumed the agent in the project's primary checkout '$PROJECT_REAL' instead of its worktree"
[ "$RESUME_CWD" = "$WT_REAL" ] \
  || fail "Herdr resumed the agent in '$RESUME_CWD', not the recorded worktree '$WT_REAL'"
case "$RESUME" in
  *fm-restore-cwd-session*) : ;;
  *) fail "Herdr's resume did not name the reported session: $RESUME" ;;
esac
pass "real herdr: a restarted server resumes the ship's agent inside its recorded worktree"

finish_lab
