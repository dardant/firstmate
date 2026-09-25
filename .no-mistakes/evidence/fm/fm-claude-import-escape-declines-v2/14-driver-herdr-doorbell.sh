#!/usr/bin/env bash
# Live: real Claude ship spawned on an isolated Herdr lab, parked on the imports
# dialog; steer it with fm-send and check the doorbell reason and the store.
set -u
ROOT=${ROOT:?}
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
TMP=$(mktemp -d /tmp/fm-r2-herdr.XXXXXX)
H="$ROOT/bin/fm-herdr-lab.sh"
S=$("$H" name r2-doorbell) || exit 1
export HERDR_SESSION="$S" HERDR_LAB_HELPER="$H" HERDR_LAB_SESSION="$S"
export TREEHOUSE_ROOT="$TMP/treehouse" CLAUDE_CONFIG_DIR="$TMP/cfg" SHELL=/bin/sh
WT=
cleanup() {
  [ -z "$WT" ] || (cd "$TMP/proj" && treehouse return --force "$WT") >/dev/null 2>&1
  "$H" teardown "$S"; echo "lab teardown rc=$?"
  rm -rf "$TMP"
}
trap cleanup EXIT
store() { node -e 'const j=require(process.argv[1]);const p=(j.projects||{})[process.argv[2]]||{};console.log("store(project root): hasClaudeMdExternalIncludesApproved="+p.hasClaudeMdExternalIncludesApproved+" hasClaudeMdExternalIncludesWarningShown="+p.hasClaudeMdExternalIncludesWarningShown)' "$TMP/cfg/.claude.json" "$(cd $TMP/proj && pwd -P)"; }
mkdir -p "$TMP/cfg" "$TMP/home/state" "$TMP/home/data/r1" "$TMP/home/config"
"$H" provision "$S" || exit 1
echo "lab session: $S (herdr $(herdr --version | head -1))"
git -C "$TMP" init -q proj; printf '# p\n' > "$TMP/proj/README.md"
git -C "$TMP/proj" add README.md; git -C "$TMP/proj" -c user.name=t -c user.email=t@e commit -qm init
git clone -q --bare "$TMP/proj" "$TMP/proj.origin.git"; git -C "$TMP/proj" remote add origin "file://$TMP/proj.origin.git"
# A fleet-home-style ancestor CLAUDE.md importing a file outside the launch dir.
printf 'rules\n' > "$TMP/AGENTS.md"; printf '@AGENTS.md\n' > "$TMP/CLAUDE.md"
node -e 'require("fs").writeFileSync(process.argv[1],JSON.stringify({hasCompletedOnboarding:true,theme:"dark",numStartups:5,projects:{}}))' "$TMP/cfg/.claude.json"
printf 'off\n' > "$TMP/home/config/herdr-presentation-spaces"
printf '# Task\n## Captain'"'"'s intent\nlive doorbell fixture\n\n## Firstmate spec\nIdle.\n' > "$TMP/home/data/r1/brief.md"
echo "## fm-spawn.sh r1 <proj> claude --backend herdr"
FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$TMP/home" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" r1 "$TMP/proj" claude --mode no-mistakes --yolo off --backend herdr 2>&1 | tail -6
echo "spawn rc=${PIPESTATUS[0]}"
WT=$(sed -n 's/^worktree=//p' "$TMP/home/state/r1.meta" | tail -1)
PANE=$(sed -n 's/^herdr_pane_id=//p' "$TMP/home/state/r1.meta" | tail -1)
echo "recorded worktree=$WT pane=$PANE"
for _ in $(seq 1 60); do "$H" run "$S" pane read "$PANE" --lines 40 2>/dev/null | grep -q 'Allow external CLAUDE.md' && break; sleep 0.5; done
echo "## pane (via lab helper pane read):"
"$H" run "$S" pane read "$PANE" --lines 40 2>/dev/null | grep -v '^\s*$' | tail -8
store
echo
echo "## fm-send.sh r1 'please rebase' (Herdr backend)"
FM_GATE_REFUSE_BYPASS=1 FM_HOME="$TMP/home" "$ROOT/bin/fm-send.sh" r1 "please rebase" 2>&1 | grep -v '^●\|WARNING: watcher'
echo "rc=${PIPESTATUS[0]}"
echo "inbox: $(ls "$TMP/home/state/r1.inbox" 2>&1 | tr '\n' ' ')"
echo "pane still on dialog: $("$H" run "$S" pane read "$PANE" --lines 40 2>/dev/null | grep -c 'Allow external CLAUDE.md')"
store
echo
echo "## fm-send.sh r1 --key Escape (Herdr backend)"
FM_GATE_REFUSE_BYPASS=1 FM_HOME="$TMP/home" "$ROOT/bin/fm-send.sh" r1 --key Escape 2>&1 | grep -v '^●\|WARNING: watcher'
echo "rc=${PIPESTATUS[0]}"
echo "pane still on dialog: $("$H" run "$S" pane read "$PANE" --lines 40 2>/dev/null | grep -c 'Allow external CLAUDE.md')"
store
echo
echo "## fm-control.sh r1 exit (Herdr backend)"
FM_GATE_REFUSE_BYPASS=1 FM_HOME="$TMP/home" "$ROOT/bin/fm-control.sh" r1 exit 2>&1; echo "rc=$?"
"$H" run "$S" pane read "$PANE" --lines 40 2>/dev/null | grep -v '^\s*$' | tail -3
store
