#!/usr/bin/env bash
# tests/fm-spawn-claude-child-session.test.sh - a Claude agent this fleet
# launches must never start with an inherited CLAUDE_CODE_CHILD_SESSION.
#
# Claude Code exports that parent-session marker into every tool shell of a
# Claude primary, and a pane can carry it into the launch. A claude started with
# it writes no transcript (docs/verification/runtime-backends.md "Claude
# transcript persistence"; the live guard is
# tests/fm-spawn-claude-transcript-live-e2e.test.sh).
#
# The assertions never read bin/fm-spawn.sh's source. They drive the real spawn
# against a fake pane and a real isolated git worktree, then EXECUTE the launch
# command the pane actually received, under a synthetic pane environment that
# carries the marker, with the harness binary replaced by a probe that prints
# what it was started with.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

CONTROL="$ROOT/bin/fm-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-claude-child-session)

# make_case <name> <harness> <id>...
# Echoes "<case-dir>|<home>|<project>|<worktree>|<fakebin>|<launch-log>|<pane-log>".
make_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog panelog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  panelog="$case_dir/pane.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  for id in "$@"; do
    fm_test_spawn_brief "$home" "$id"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog|$panelog"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG PANE_LOG <<EOF
$1
EOF
}

run_case_spawn() {
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

# Replace the harness binary with a probe that reports the marker it inherited.
install_marker_probe() {  # <fakebin> <harness>
  cat > "$1/$2" <<'SH'
#!/bin/sh
printf '%s\n' "${CLAUDE_CODE_CHILD_SESSION-unset}"
SH
  chmod +x "$1/$2"
}

# Run the emitted launch in a synthetic pane shell that carries the marker, the
# way a pane opened from a Claude primary's shell or from a backend server that
# shell started does. The pane exports replay first, as in the real pane.
#   emitted_launch_marker <fakebin> <launch-log> <pane-log>
emitted_launch_marker() {
  local fakebin=$1 launchlog=$2 panelog=$3 launch preamble
  launch=$(cat "$launchlog")
  preamble=$(grep '^export ' "$panelog")
  env -i HOME="$TMP_ROOT/pane-home" PATH="$fakebin:$PATH" TERM=xterm \
    TMUX=synthetic-pane CLAUDE_CODE_CHILD_SESSION=1 \
    /bin/sh -c "$preamble
$launch"
}

# The synthetic pane must really carry the marker, or an "unset" verdict below
# would pass without proving anything.
assert_pane_carries_marker() {  # <fakebin>
  local seen
  seen=$(env -i PATH="$1:$PATH" CLAUDE_CODE_CHILD_SESSION=1 /bin/sh -c claude)
  assert_equals 1 "$seen" "the synthetic pane must hand the marker to an unwrapped claude"
}

test_ship_and_scout() {
  local setting kind rec out status seen
  for setting in absent enabled; do
    for kind in ship scout; do
      rec=$(make_case "$kind-$setting" claude "$kind-$setting-a1")
      read_case "$rec"
      [ "$setting" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
      if [ "$kind" = ship ]; then
        out=$(run_case_spawn "$kind-$setting-a1" "$PROJ_DIR" --mode no-mistakes --yolo off)
      else
        out=$(run_case_spawn "$kind-$setting-a1" "$PROJ_DIR" --scout)
      fi
      status=$?
      expect_code 0 "$status" "$kind spawn with allowlist=$setting should succeed: $out"
      install_marker_probe "$FAKEBIN_DIR" claude
      assert_pane_carries_marker "$FAKEBIN_DIR"
      seen=$(emitted_launch_marker "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG") \
        || fail "$kind, allowlist $setting: the emitted launch failed to run"
      assert_equals unset "$seen" \
        "a $kind claude launched with allowlist=$setting from a marked pane must not inherit CLAUDE_CODE_CHILD_SESSION"
    done
  done
  pass "ship and scout claude launches drop the inherited parent-session marker in both allowlist postures"
}

# An operator allowlist that names the marker must not bring it back.
test_allowlisted_marker_is_still_dropped() {
  local rec out status seen
  rec=$(make_case allowlisted claude allowlisted-a1)
  read_case "$rec"
  printf 'CLAUDE_CODE_CHILD_SESSION\n' > "$HOME_DIR/config/launch-env-allowlist"
  out=$(run_case_spawn allowlisted-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn with the marker allowlisted should succeed: $out"
  install_marker_probe "$FAKEBIN_DIR" claude
  seen=$(emitted_launch_marker "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG") \
    || fail "allowlisted marker: the emitted launch failed to run"
  assert_equals unset "$seen" \
    "an allowlist entry for the marker must not carry it into the claude process"
  pass "an allowlisted marker still never reaches the launched claude"
}

test_secondmate_launch() {
  local setting rec sm out status seen
  for setting in absent enabled; do
    rec=$(make_case "secondmate-$setting" claude "sm-$setting")
    read_case "$rec"
    [ "$setting" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
    sm="$CASE_DIR/secondmate-home"
    mkdir -p "$sm/bin" "$sm/data"
    printf '# Firstmate\n' > "$sm/AGENTS.md"
    printf '%s\n' "sm-$setting" > "$sm/.fm-secondmate-home"
    printf 'charter for sm-%s\n' "$setting" > "$sm/data/charter.md"
    # Real secondmate homes are firstmate clones, and the spawn installs its
    # commit-trailer hooks into that git worktree.
    printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$sm/.gitignore"
    git -C "$sm" init -q -b main
    out=$(run_case_spawn "sm-$setting" "$sm" --secondmate)
    status=$?
    expect_code 0 "$status" "secondmate spawn with allowlist=$setting should succeed: $out"
    install_marker_probe "$FAKEBIN_DIR" claude
    seen=$(emitted_launch_marker "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG") \
      || fail "secondmate, allowlist $setting: the emitted launch failed to run"
    assert_equals unset "$seen" \
      "a claude secondmate launched with allowlist=$setting must not inherit CLAUDE_CODE_CHILD_SESSION"
  done
  pass "a claude secondmate launch drops the inherited parent-session marker in both allowlist postures"
}

# --- relaunch ---------------------------------------------------------------
#
# bin/fm-control.sh relaunch rebuilds the launch through bin/fm-spawn.sh
# --relaunch; the stub models only the pane lifecycle that transaction needs.
make_relaunch_stub() {  # <case-dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'")
          staged=${payload#". '"}
          staged=${staged%"'"}
          [ ! -f "$staged" ] || payload=$(cat "$staged")
          ;;
      esac
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit) printf 'zsh' > "$D/command" ;;
        *'encode launch-brief'*) printf 'claude' > "$D/command" ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
}

test_relaunch_drops_the_marker() {
  local dir home proj wt id out status seen launch preamble
  id=relaunch-a1
  dir="$TMP_ROOT/relaunch"
  home="$dir/home"
  proj="$dir/proj"
  wt="$dir/wt"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$dir/fake" "$dir/user-home"
  touch "$home/state/.last-watcher-beat"
  make_relaunch_stub "$dir"
  fm_git_worktree "$proj" "$wt" wt-relaunch
  fm_test_spawn_brief "$home" "$id"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'claude' > "$dir/fake/command"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$wt" > "$dir/fake/cwd"
  fm_write_meta "$home/state/$id.meta" \
    "window=fmses:fm-$id" "endpoint_task_id=$id" "worktree=$wt" "project=$proj" \
    harness=claude kind=ship mode=no-mistakes yolo=off "tasktmp=$dir/tasktmp" \
    model=default effort=default

  out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$CONTROL" "$id" relaunch --note 'replacement continues the same task' 2>&1)
  status=$?
  expect_code 0 "$status" "claude relaunch should succeed: $out"
  launch=$(grep 'encode launch-brief' "$dir/fake/literal" | tail -1)
  [ -n "$launch" ] || fail "claude relaunch sent no replacement launch command"
  install_marker_probe "$dir/fakebin" claude
  preamble=$(grep '^export ' "$dir/fake/keys")
  seen=$(env -i HOME="$dir/user-home" PATH="$dir/fakebin:$PATH" TERM=xterm \
    TMUX=synthetic-pane CLAUDE_CODE_CHILD_SESSION=1 \
    /bin/sh -c "$preamble
$launch") \
    || fail "claude relaunch: the replacement launch failed to run"
  assert_equals unset "$seen" \
    "a relaunched claude must drop the inherited parent-session marker exactly as a fresh spawn does"
  pass "relaunch drops the inherited parent-session marker for the replacement claude"
}

test_ship_and_scout
test_allowlisted_marker_is_still_dropped
test_secondmate_launch
test_relaunch_drops_the_marker
