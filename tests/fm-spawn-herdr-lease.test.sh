#!/usr/bin/env bash
# bin/fm-spawn.sh: a Herdr ship or scout leases its worktree before its tab
# exists and opens the tab inside it.
#
# Herdr restores a pane, and resumes its agent, in the pane's root shell
# directory, so a tab opened in the project resumed the worker in the primary
# checkout after a server restart (tests/fm-backend-herdr-restore-cwd-e2e.test.sh
# proves that against a real Herdr lab). This pins the spawn ordering with no
# Herdr and no Treehouse installed: a stateful fake of each records every call.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-herdr-lease)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (the herdr adapter parses JSON with it)"; exit 0; }

# make_fakes <case-dir>: a Treehouse that leases one prepared slot, and a
# Herdr whose one task pane reports the directory its tab was created in.
make_fakes() {
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
D=$FAKE_DIR
printf '%s\n' "$*" >> "$D/treehouse-log"
case "${1:-} ${2:-}" in
  'get --lease') printf '%s\n' "$(cat "$D/slot")"; exit 0 ;;
  'return --help') printf '      --force   Clean, reset, and return without prompting\n'; exit 0 ;;
  'status --json') if [ -f "$D/status" ]; then cat "$D/status"; else printf '[]\n'; fi; exit 0 ;;
esac
exit 0
SH
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
D=$FAKE_DIR
printf '%s\n' "$*" >> "$D/herdr-log"
case "${1:-}" in
  --version) printf 'herdr 0.9.0\n'; exit 0 ;;
  server) exit 0 ;;
  status) printf '{"client":{"version":"0.9.0","protocol":22},"server":{"running":true,"version":"0.9.0","protocol":22}}\n'; exit 0 ;;
esac
arg_after() { local want=$1 prev= a; shift; for a in "$@"; do [ "$prev" = "$want" ] && { printf '%s' "$a"; return; }; prev=$a; done; }
case "${1:-} ${2:-}" in
  'workspace list')
    if [ -f "$D/workspace" ]; then
      printf '{"result":{"workspaces":[{"workspace_id":"ws1","label":"%s"}]}}\n' "$(cat "$D/workspace")"
    else
      printf '{"result":{"workspaces":[]}}\n'
    fi
    exit 0 ;;
  'workspace create')
    arg_after --label "$@" > "$D/workspace"
    printf '{"result":{"workspace":{"workspace_id":"ws1"},"tab":{"tab_id":"seedtab"},"root_pane":{"pane_id":"ws1:p0"}}}\n'
    exit 0 ;;
  'tab list') printf '{"result":{"tabs":[]}}\n'; exit 0 ;;
  'session list')
    printf '{"sessions":[{"name":"fmlab","running":true,"socket_path":"%s/herdr.sock"}]}\n' "$D"
    exit 0 ;;
  'tab create')
    arg_after --cwd "$@" > "$D/cwd"
    printf '{"result":{"tab":{"tab_id":"tab1","workspace_id":"ws1"},"root_pane":{"pane_id":"ws1:p1"}}}\n'
    exit 0 ;;
  'tab get') printf '{"result":{"tab":{"tab_id":"tab1","workspace_id":"ws1"}}}\n'; exit 0 ;;
  'pane get')
    if [ -f "$D/pane-closed" ]; then
      printf '{"error":{"code":"pane_not_found"}}\n'
    else
      printf '{"result":{"pane":{"pane_id":"%s","tab_id":"tab1","workspace_id":"ws1","cwd":"%s","foreground_cwd":"%s"}}}\n' \
        "${3:-}" "$(cat "$D/cwd" 2>/dev/null)" "$(cat "$D/cwd" 2>/dev/null)"
    fi
    exit 0 ;;
  'pane close' | 'tab close' | 'workspace close')
    # With agent-survives armed, the launched harness outlives every cleanup,
    # as after the kimi or backlog-commit failures, which close nothing.
    [ -f "$D/agent-survives" ] || : > "$D/pane-closed"
    exit 0 ;;
  'pane send-text')
    # The launch line starts the harness; with agent-registers armed, Herdr's
    # integration has also registered it by the time anything asks.
    case "${4:-}" in
      '. '*)
        : > "$D/launched"
        [ ! -f "$D/agent-registers" ] || : > "$D/agent-live" ;;
    esac
    exit 0 ;;
  'agent get')
    if [ -f "$D/agent-live" ]; then
      printf '{"result":{"agent":{"agent_status":"working"}}}\n'
    else
      printf '{"error":{"code":"agent_not_found"}}\n'
    fi
    exit 0 ;;
  'pane process-info')
    if [ -f "$D/launched" ]; then
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":4242,"foreground_process_group_id":4243,"foreground_processes":[{"pid":4243,"name":"rovo","argv":["rovo"],"cmdline":"rovo run"}]}}}\n' "${4:-}"
    else
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":4242,"foreground_process_group_id":4242,"foreground_processes":[{"pid":4242,"name":"bash","argv":["bash"],"cmdline":"bash"}]}}}\n' "${4:-}"
    fi
    exit 0 ;;
esac
exit 0
SH
  printf '#!/usr/bin/env bash\nexec sleep 30\n' > "$fb/rovo"
  chmod +x "$fb/treehouse" "$fb/herdr" "$fb/rovo"
}

# new_case <name> <id> [pool] -> case dir with a project, a leasable slot, a
# home, and fakes. With `pool`, the slot sits in a Treehouse pool layout, so
# the spawn claims it as a pool slot.
new_case() {
  local dir="$TMP_ROOT/$1" id=$2 slot="$TMP_ROOT/$1/slot"
  mkdir -p "$dir/home/state" "$dir/home/data/$id" "$dir/home/config" "$dir/fake"
  if [ "${3:-}" = pool ]; then
    mkdir -p "$dir/pool/s1"
    printf '{}\n' > "$dir/pool/treehouse-state.json"
    slot="$dir/pool/s1/slot"
  fi
  fm_git_worktree "$dir/proj" "$slot" "slot-$id"
  printf '%s' "$(cd "$slot" && pwd -P)" > "$dir/fake/slot"
  : > "$dir/fake/treehouse-log"
  : > "$dir/fake/herdr-log"
  printf 'off\n' > "$dir/home/config/herdr-presentation-spaces"
  cat > "$dir/home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise the herdr worktree lease for $id.

## Firstmate spec
Stay idle.
EOF
  make_fakes "$dir"
  printf '%s\n' "$dir"
}

run_spawn() {  # <case-dir> <id> [agent-arg...]
  local dir=$1 id=$2
  shift 2
  [ "$#" -gt 0 ] || set -- "sh -c 'sleep 1'"
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FAKE_DIR="$dir/fake" HERDR_SESSION=fmlab \
    FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1 \
    FM_ROVO_READY_POLLS=1 FM_ROVO_POLL_INTERVAL=0 \
    "$SPAWN" "$id" "$dir/proj" "$@" --mode no-mistakes --yolo off --backend herdr 2>&1
}

# arm_misplaced_pane <case-dir>: the task pane reports a directory other than
# the leased worktree, so the spawn refuses after the lease and before any
# task record exists.
# shellcheck disable=SC2016 # The single-quoted $D and $@ are the fake herdr's own text.
arm_misplaced_pane() {
  sed -i.bak 's|arg_after --cwd "\$@" > "\$D/cwd"|printf %s "$D" > "$D/cwd"|' "$1/fakebin/herdr"
  grep -q 'printf %s "$D" > "$D/cwd"' "$1/fakebin/herdr" || fail "the fixture did not arm the misplaced pane"
}

test_herdr_ship_tab_opens_in_its_leased_worktree() {
  local dir out rc=0 slot create
  dir=$(new_case opens-in-slot lease1)
  slot=$(cat "$dir/fake/slot")
  out=$(run_spawn "$dir" lease1) || rc=$?
  expect_code 0 "$rc" "a herdr ship spawn should succeed"$'\n'"$out"$'\n'"$(cat "$dir/fake/herdr-log")"
  assert_contains "$(cat "$dir/fake/treehouse-log")" "get --lease --lease-holder fm-task-lease1" \
    "the ship should lease its worktree under its own holder label"
  create=$(grep '^tab create' "$dir/fake/herdr-log" | head -1)
  assert_contains "$create" "--cwd $slot" "the task tab should open in the leased worktree, got: $create"
  assert_not_contains "$(cat "$dir/fake/herdr-log")" "treehouse get" \
    "a leased ship must not also run the interactive treehouse get in its pane"
  [ "$(sed -n 's/^worktree=//p' "$dir/home/state/lease1.meta" | tail -1)" = "$slot" ] \
    || fail "the task record should name the leased worktree"
  pass "fm-spawn herdr: a ship leases its worktree first and opens its tab inside it"
}

test_herdr_ship_abort_returns_its_lease() {
  local dir out rc=0 slot
  dir=$(new_case abort-returns lease2)
  slot=$(cat "$dir/fake/slot")
  arm_misplaced_pane "$dir"
  out=$(run_spawn "$dir" lease2) || rc=$?
  [ "$rc" -ne 0 ] || fail "a ship whose pane is not in its leased worktree must refuse"$'\n'"$out"
  assert_contains "$out" "not its leased worktree" "the refusal should name the leased worktree"
  [ ! -e "$dir/home/state/lease2.meta" ] || fail "an aborted spawn must publish no task record"
  assert_contains "$(cat "$dir/fake/treehouse-log")" "return --force $slot" \
    "an abort before the record exists should return the worktree it leased"
  pass "fm-spawn herdr: an abort before the task record returns the leased worktree"
}

# `treehouse return --force` cleans and resets the slot, so an abort must never
# return a leased slot holding work, the same way the freshen gate refuses a
# dirty pooled slot without touching it.
test_herdr_ship_abort_keeps_a_dirty_lease() {
  local dir out rc=0 slot
  dir=$(new_case abort-dirty lease3)
  slot=$(cat "$dir/fake/slot")
  printf 'unsaved\n' > "$slot/wip.txt"
  arm_misplaced_pane "$dir"
  out=$(run_spawn "$dir" lease3) || rc=$?
  [ "$rc" -ne 0 ] || fail "a ship whose pane is not in its leased worktree must refuse"$'\n'"$out"
  [ ! -e "$dir/home/state/lease3.meta" ] || fail "an aborted spawn must publish no task record"
  assert_not_contains "$(cat "$dir/fake/treehouse-log")" "return --force" \
    "an abort must not return a leased worktree that holds uncommitted work"
  [ "$(cat "$slot/wip.txt" 2>/dev/null)" = unsaved ] || fail "the aborted spawn lost the slot's uncommitted work"
  assert_contains "$out" "not provably clean" "the warning should say why the lease was kept"
  assert_contains "$out" "treehouse return --force '$slot'" "the warning should name the manual return"
  pass "fm-spawn herdr: an abort keeps a leased worktree that holds work and names the manual return"
}

# An abort after the record was published (here rovo's readiness gate) rolls
# the record back after the Treehouse project lock was released, so the lease
# block takes that lock again rather than stranding a durable lease.
test_herdr_ship_abort_after_publish_returns_its_lease() {
  local dir out rc=0 slot
  dir=$(new_case abort-after-publish lease4)
  slot=$(cat "$dir/fake/slot")
  out=$(run_spawn "$dir" lease4 --harness rovo) || rc=$?
  [ "$rc" -ne 0 ] || fail "a rovo ship that never shows ready must refuse"$'\n'"$out"
  assert_contains "$out" "rovo did not show a verified ready signal" \
    "the spawn should abort at rovo's post-publish readiness gate"$'\n'"$out"
  [ ! -e "$dir/home/state/lease4.meta" ] || fail "the aborted spawn's record should be rolled back"
  assert_contains "$(cat "$dir/fake/treehouse-log")" "return --force $slot" \
    "an abort after publication should return the worktree it leased"$'\n'"$out"
  assert_not_contains "$out" "leased worktree $slot in place" \
    "an abort after publication must not strand the lease"
  pass "fm-spawn herdr: an abort after the record was published still returns the leased worktree"
}

# Once the launch line may have reached the pane, a clean slot is still kept
# while its agent is not proven gone: returning it would let the next spawn
# lease a worktree an orphaned worker is still editing.
test_herdr_ship_abort_after_launch_keeps_a_live_agents_lease() {
  local dir out rc=0 slot
  dir=$(new_case abort-live-agent lease5)
  slot=$(cat "$dir/fake/slot")
  : > "$dir/fake/agent-survives"
  : > "$dir/fake/agent-registers"
  out=$(run_spawn "$dir" lease5 --harness rovo) || rc=$?
  [ "$rc" -ne 0 ] || fail "a rovo ship that never shows ready must refuse"$'\n'"$out"
  [ -f "$dir/fake/agent-live" ] || fail "the fixture's launch never started the surviving agent"$'\n'"$out"
  [ ! -e "$dir/home/state/lease5.meta" ] || fail "the aborted spawn's record should be rolled back"
  assert_not_contains "$(cat "$dir/fake/treehouse-log")" "return --force" \
    "an abort must not return a leased worktree whose launched agent is still alive"$'\n'"$out"
  assert_contains "$out" "not proven agent-free" "the warning should say why the lease was kept"
  assert_contains "$out" "treehouse return --force '$slot'" "the warning should name the manual return"
  pass "fm-spawn herdr: an abort after launch keeps the lease while its agent is still alive"
}

# Herdr registers an agent only once its integration reports it, so a harness
# still booting reads `agent_not_found` while it already runs in the pane's
# foreground. That is no proof the worktree is free.
test_herdr_ship_abort_after_launch_keeps_a_booting_agents_lease() {
  local dir out rc=0 slot
  dir=$(new_case abort-booting-agent lease6)
  slot=$(cat "$dir/fake/slot")
  : > "$dir/fake/agent-survives"
  out=$(run_spawn "$dir" lease6 --harness rovo) || rc=$?
  [ "$rc" -ne 0 ] || fail "a rovo ship that never shows ready must refuse"$'\n'"$out"
  [ -f "$dir/fake/launched" ] || fail "the fixture's launch never started the booting agent"$'\n'"$out"
  [ ! -e "$dir/fake/agent-live" ] || fail "the booting agent must stay unregistered for this case"
  [ ! -e "$dir/home/state/lease6.meta" ] || fail "the aborted spawn's record should be rolled back"
  assert_not_contains "$(cat "$dir/fake/treehouse-log")" "return --force" \
    "an abort must not return a leased worktree whose unregistered harness is still running"$'\n'"$out"
  assert_contains "$out" "not proven agent-free" "the warning should say why the lease was kept"
  assert_contains "$out" "treehouse return --force '$slot'" "the warning should name the manual return"
  pass "fm-spawn herdr: an abort after launch keeps the lease while an unregistered harness still runs"
}

# write_leased_record <case-dir> <id> <worktree> <holder>: an existing task
# record naming <worktree> on an agent-free Herdr pane, as a restart husk
# leaves it, and a Treehouse that reports <worktree> leased to <holder>.
write_leased_record() {
  local dir=$1 id=$2 wt=$3 holder=$4
  fm_write_meta "$dir/home/state/$id.meta" "window=fmlab:ws1:p9" "worktree=$wt" \
    "project=$dir/proj" "kind=ship" "backend=herdr" "herdr_session=fmlab" \
    "herdr_workspace_id=ws1" "herdr_tab_id=tab9" "herdr_pane_id=ws1:p9"
  printf '[{"name":"1","path":"%s","status":"leased","lease_id":"l1","lease_holder":"%s","processes":[]}]\n' \
    "$wt" "$holder" > "$dir/fake/status"
}

# A same-identity respawn after a Herdr restart finds its record naming a
# worktree that Treehouse still holds under this task's own lease. It reuses
# that worktree exactly as it stands: nothing new is leased, nothing is
# returned, its work and slot claim survive, and the new record names it.
test_herdr_ship_fresh_spawn_reuses_its_leased_record() {
  local dir out rc=0 slot create
  dir=$(new_case respawn-reuses lease7 pool)
  slot=$(cat "$dir/fake/slot")
  write_leased_record "$dir" lease7 "$slot" fm-task-lease7
  printf 'task=lease7\nhome=%s\n' "$dir/home" > "$(dirname "$slot")/.fm-slot-owner"
  printf 'in progress\n' > "$slot/wip.txt"
  out=$(run_spawn "$dir" lease7) || rc=$?
  expect_code 0 "$rc" "a fresh spawn over its own leased record should reuse it"$'\n'"$out"
  assert_not_contains "$(cat "$dir/fake/treehouse-log")" "get --lease" "the respawn must lease no second worktree"
  assert_not_contains "$(cat "$dir/fake/treehouse-log")" "return" "the respawn must not return the reused worktree"
  create=$(grep '^tab create' "$dir/fake/herdr-log" | head -1)
  assert_contains "$create" "--cwd $slot" "the respawned tab should open in the recorded worktree, got: $create"
  [ "$(sed -n 's/^worktree=//p' "$dir/home/state/lease7.meta" | tail -1)" = "$slot" ] \
    || fail "the respawned record should still name the reused worktree"
  [ "$(cat "$slot/wip.txt" 2>/dev/null)" = "in progress" ] || fail "the respawn discarded the reused worktree's work"
  assert_contains "$(cat "$(dirname "$slot")/.fm-slot-owner" 2>/dev/null)" "task=lease7" \
    "the reused slot should still be claimed by its task"
  pass "fm-spawn herdr: a fresh spawn over its own leased record reuses that worktree and leases nothing"
}

# An aborted respawn never returns the reused worktree: it holds the task's
# work. The rollback restores the prior record, so the lease stays named and
# the next respawn reuses the same worktree rather than leasing another.
test_herdr_ship_aborted_respawn_keeps_the_reused_lease() {
  local dir out rc=0 slot before
  dir=$(new_case respawn-abort lease10)
  slot=$(cat "$dir/fake/slot")
  write_leased_record "$dir" lease10 "$slot" fm-task-lease10
  before=$(cat "$dir/home/state/lease10.meta")
  out=$(run_spawn "$dir" lease10 --harness rovo) || rc=$?
  [ "$rc" -ne 0 ] || fail "a rovo respawn that never shows ready must refuse"$'\n'"$out"
  assert_contains "$out" "rovo did not show a verified ready signal" \
    "the respawn should abort at rovo's post-publish readiness gate"$'\n'"$out"
  assert_not_contains "$(cat "$dir/fake/treehouse-log")" "get --lease" "the respawn must lease no second worktree"
  assert_not_contains "$(cat "$dir/fake/treehouse-log")" "return --force" \
    "an aborted respawn must not return the task's reused worktree"$'\n'"$out"
  [ -d "$slot" ] || fail "the aborted respawn removed the reused worktree"
  [ "$(cat "$dir/home/state/lease10.meta" 2>/dev/null)" = "$before" ] \
    || fail "the aborted respawn should restore the prior record"$'\n'"$out"
  assert_not_contains "$out" "no task record names it" "a restored record must not be reported as orphaned"
  [ -z "$(find "$dir/home/state" -name '.lease10.meta.*' 2>/dev/null)" ] \
    || fail "the aborted respawn left a record snapshot behind: $(ls -a "$dir/home/state")"

  rm -f "$dir/fake/pane-closed" "$dir/fake/launched"
  : > "$dir/fake/treehouse-log"
  rc=0
  out=$(run_spawn "$dir" lease10) || rc=$?
  expect_code 0 "$rc" "a respawn over the restored record should reuse its worktree"$'\n'"$out"
  assert_not_contains "$(cat "$dir/fake/treehouse-log")" "get --lease" "the next respawn must lease no second worktree"
  assert_not_contains "$(cat "$dir/fake/treehouse-log")" "return" "the next respawn must not return the reused worktree"
  [ "$(sed -n 's/^worktree=//p' "$dir/home/state/lease10.meta" | tail -1)" = "$slot" ] \
    || fail "the next respawn's record should name the same reused worktree"
  pass "fm-spawn herdr: an aborted respawn restores the prior record, and the next respawn reuses the same worktree"
}

# A respawn whose backlog commit fails after publication restores the prior
# record, so its guidance must keep the reused worktree: closing out that copy
# would discard the task's work and leave the restored record naming a slot
# back in the pool.
test_herdr_ship_respawn_backlog_failure_keeps_the_worktree() {
  local dir out rc=0 slot before real
  real=$(command -v tasks-axi) || { echo "skip: tasks-axi not found (backlog commit failure case)"; return 0; }
  dir=$(new_case respawn-backlog lease13)
  slot=$(cat "$dir/fake/slot")
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$dir/home/data/backlog.md"
  printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\n' > "$dir/home/.tasks.toml"
  tasks-axi add lease13 "item for lease13" --kind ship --file "$dir/home/data/backlog.md" >/dev/null \
    || fail "the fixture could not add the backlog item"
  cat > "$dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = start ]; then
  echo 'error: "backlog is unwritable"' >&2
  exit 1
fi
exec "$real" "\$@"
SH
  chmod +x "$dir/fakebin/tasks-axi"
  write_leased_record "$dir" lease13 "$slot" fm-task-lease13
  before=$(cat "$dir/home/state/lease13.meta")
  out=$(run_spawn "$dir" lease13) || rc=$?
  [ "$rc" -ne 0 ] || fail "a respawn whose backlog commit fails must refuse"$'\n'"$out"
  assert_contains "$out" "could not be moved to In flight" "the respawn should fail at the backlog commit"$'\n'"$out"
  assert_contains "$out" "prior record was restored and still names its worktree $slot" \
    "the failure should say the prior record still names the worktree"$'\n'"$out"
  assert_not_contains "$out" "local copy $slot by hand" "the failure must not tell the operator to close out the reused worktree"
  [ "$(cat "$dir/home/state/lease13.meta" 2>/dev/null)" = "$before" ] \
    || fail "the failed respawn should restore the prior record"$'\n'"$out"
  assert_not_contains "$(cat "$dir/fake/treehouse-log")" "return --force" "the failed respawn must not return the reused worktree"
  pass "fm-spawn herdr: a respawn whose backlog commit fails restores the record and keeps its worktree"
}

# When the prior record cannot be put back, the snapshot is the only copy of
# it, so it survives the exit where the error names it.
test_herdr_ship_failed_restore_keeps_the_snapshot() {
  local dir out rc=0 slot before snap real_mv
  real_mv=$(command -v mv)
  dir=$(new_case respawn-restore-fails lease14)
  slot=$(cat "$dir/fake/slot")
  cat > "$dir/fakebin/mv" <<SH
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in *.respawn-prior.*) exit 1 ;; esac; done
exec "$real_mv" "\$@"
SH
  chmod +x "$dir/fakebin/mv"
  write_leased_record "$dir" lease14 "$slot" fm-task-lease14
  before=$(cat "$dir/home/state/lease14.meta")
  out=$(run_spawn "$dir" lease14 --harness rovo) || rc=$?
  [ "$rc" -ne 0 ] || fail "a rovo respawn that never shows ready must refuse"$'\n'"$out"
  snap=$(printf '%s\n' "$out" | sed -n "s/.*restore it by hand from \([^ ]*\) to .*/\1/p" | head -1)
  [ -n "$snap" ] || fail "the failed restore should name the kept snapshot"$'\n'"$out"
  [ -f "$snap" ] || fail "the failed restore deleted the snapshot its error names: $snap"
  [ "$(cat "$snap")" = "$before" ] || fail "the kept snapshot should hold the prior record"
  assert_not_contains "$(cat "$dir/fake/treehouse-log")" "return --force" "the failed respawn must not return the reused worktree"
  pass "fm-spawn herdr: a failed prior-record restore keeps the snapshot its error names"
}

# A record whose worktree is gone, or is leased to another holder, cannot be
# reused; a fresh spawn over it refuses before leasing and points to relaunch.
test_herdr_ship_refuses_fresh_spawn_over_an_unreusable_record() {
  local dir out rc=0 before slot
  dir=$(new_case respawn-missing lease11)
  write_leased_record "$dir" lease11 "$dir/old-slot" fm-task-lease11
  before=$(cat "$dir/home/state/lease11.meta")
  out=$(run_spawn "$dir" lease11) || rc=$?
  [ "$rc" -ne 0 ] || fail "a fresh spawn over a record naming a missing worktree must refuse"$'\n'"$out"
  assert_contains "$out" "record already names worktree '$dir/old-slot'" "the refusal should name the recorded worktree"
  assert_contains "$out" "no longer exists" "the refusal should say why the worktree cannot be reused"
  assert_contains "$out" "fm-control.sh lease11 relaunch" "the refusal should point to relaunch"
  assert_not_contains "$(cat "$dir/fake/treehouse-log")" "get --lease" "the refused spawn must lease nothing"
  [ "$(cat "$dir/home/state/lease11.meta")" = "$before" ] || fail "the refused spawn changed the existing record"

  rc=0
  dir=$(new_case respawn-foreign lease12)
  slot=$(cat "$dir/fake/slot")
  write_leased_record "$dir" lease12 "$slot" fm-task-other
  before=$(cat "$dir/home/state/lease12.meta")
  out=$(run_spawn "$dir" lease12) || rc=$?
  [ "$rc" -ne 0 ] || fail "a fresh spawn over a worktree leased to another holder must refuse"$'\n'"$out"
  assert_contains "$out" "leased to 'fm-task-other', not 'fm-task-lease12'" "the refusal should name the foreign holder"
  assert_contains "$out" "fm-control.sh lease12 relaunch" "the refusal should point to relaunch"
  assert_not_contains "$(cat "$dir/fake/treehouse-log")" "get --lease" "the refused spawn must lease nothing"
  assert_not_contains "$(cat "$dir/fake/treehouse-log")" "return" "the refused spawn must return nothing"
  [ "$(cat "$dir/home/state/lease12.meta")" = "$before" ] || fail "the refused spawn changed the existing record"
  pass "fm-spawn herdr: a fresh spawn over a record whose worktree is gone or not its lease refuses before leasing"
}

# The abort return keys on whether this spawn leased the slot and a surviving
# record names it, not on a record merely existing: a record that names no
# worktree does not own the slot this spawn just leased.
test_herdr_ship_abort_returns_a_lease_no_record_names() {
  local dir out rc=0 slot
  dir=$(new_case abort-unnamed lease8)
  slot=$(cat "$dir/fake/slot")
  fm_write_meta "$dir/home/state/lease8.meta" "window=fmlab:ws1:p9" "kind=ship" "backend=herdr"
  arm_misplaced_pane "$dir"
  out=$(run_spawn "$dir" lease8) || rc=$?
  [ "$rc" -ne 0 ] || fail "a ship whose pane is not in its leased worktree must refuse"$'\n'"$out"
  assert_contains "$out" "not its leased worktree" "the refusal should name the leased worktree"
  assert_contains "$(cat "$dir/fake/treehouse-log")" "return --force $slot" \
    "an abort should return a leased worktree no surviving record names"$'\n'"$out"
  pass "fm-spawn herdr: an abort returns a leased worktree that the surviving record does not name"
}

# After publication the project lock was released, so the lease return takes
# it again; the slot claim is then released under that same lock rather than
# left on a slot already back in the pool.
test_herdr_ship_abort_after_publish_releases_its_slot_claim() {
  local dir out rc=0 slot
  dir=$(new_case abort-claim lease9 pool)
  slot=$(cat "$dir/fake/slot")
  out=$(run_spawn "$dir" lease9 --harness rovo) || rc=$?
  [ "$rc" -ne 0 ] || fail "a rovo ship that never shows ready must refuse"$'\n'"$out"
  assert_contains "$(cat "$dir/fake/treehouse-log")" "return --force $slot" \
    "an abort after publication should return the pooled worktree it leased"$'\n'"$out"
  [ ! -e "$(dirname "$slot")/.fm-slot-owner" ] || fail "the returned slot still carries this task's claim"$'\n'"$out"
  assert_not_contains "$out" "slot claim on" "an abort that returned the slot must not report leaving its claim"
  pass "fm-spawn herdr: an abort after publication returns the slot and releases its claim"
}

test_herdr_ship_tab_opens_in_its_leased_worktree
test_herdr_ship_fresh_spawn_reuses_its_leased_record
test_herdr_ship_aborted_respawn_keeps_the_reused_lease
test_herdr_ship_respawn_backlog_failure_keeps_the_worktree
test_herdr_ship_failed_restore_keeps_the_snapshot
test_herdr_ship_refuses_fresh_spawn_over_an_unreusable_record
test_herdr_ship_abort_returns_its_lease
test_herdr_ship_abort_returns_a_lease_no_record_names
test_herdr_ship_abort_after_publish_releases_its_slot_claim
test_herdr_ship_abort_keeps_a_dirty_lease
test_herdr_ship_abort_after_publish_returns_its_lease
test_herdr_ship_abort_after_launch_keeps_a_live_agents_lease
test_herdr_ship_abort_after_launch_keeps_a_booting_agents_lease
