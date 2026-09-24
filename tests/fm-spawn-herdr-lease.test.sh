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
  'tab create')
    arg_after --cwd "$@" > "$D/cwd"
    printf '{"result":{"tab":{"tab_id":"tab1","workspace_id":"ws1"},"root_pane":{"pane_id":"ws1:p1"}}}\n'
    exit 0 ;;
  'tab get') printf '{"result":{"tab":{"tab_id":"tab1","workspace_id":"ws1"}}}\n'; exit 0 ;;
  'pane get')
    printf '{"result":{"pane":{"pane_id":"%s","tab_id":"tab1","workspace_id":"ws1","cwd":"%s","foreground_cwd":"%s"}}}\n' \
      "${3:-}" "$(cat "$D/cwd" 2>/dev/null)" "$(cat "$D/cwd" 2>/dev/null)"
    exit 0 ;;
  'agent get') printf '{"error":{"code":"agent_not_found"}}\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/treehouse" "$fb/herdr"
}

# new_case <name> <id> -> case dir with a project, a leasable slot, a home, and fakes.
new_case() {
  local dir="$TMP_ROOT/$1" id=$2
  mkdir -p "$dir/home/state" "$dir/home/data/$id" "$dir/home/config" "$dir/fake"
  fm_git_worktree "$dir/proj" "$dir/slot" "slot-$id"
  printf '%s' "$(cd "$dir/slot" && pwd -P)" > "$dir/fake/slot"
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

run_spawn() {  # <case-dir> <id>
  local dir=$1 id=$2
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FAKE_DIR="$dir/fake" HERDR_SESSION=fmlab \
    FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1 \
    "$SPAWN" "$id" "$dir/proj" "sh -c 'sleep 1'" --mode no-mistakes --yolo off --backend herdr 2>&1
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
  # A pane that opens anywhere but the leased worktree refuses after the lease.
  sed -i.bak 's|arg_after --cwd "\$@" > "\$D/cwd"|printf %s "$D" > "$D/cwd"|' "$dir/fakebin/herdr"
  grep -q 'printf %s "$D" > "$D/cwd"' "$dir/fakebin/herdr" || fail "the fixture did not arm the misplaced pane"
  out=$(run_spawn "$dir" lease2) || rc=$?
  [ "$rc" -ne 0 ] || fail "a ship whose pane is not in its leased worktree must refuse"$'\n'"$out"
  assert_contains "$out" "not its leased worktree" "the refusal should name the leased worktree"
  [ ! -e "$dir/home/state/lease2.meta" ] || fail "an aborted spawn must publish no task record"
  assert_contains "$(cat "$dir/fake/treehouse-log")" "return --force $slot" \
    "an abort before the record exists should return the worktree it leased"
  pass "fm-spawn herdr: an abort before the task record returns the leased worktree"
}

test_herdr_ship_tab_opens_in_its_leased_worktree
test_herdr_ship_abort_returns_its_lease
