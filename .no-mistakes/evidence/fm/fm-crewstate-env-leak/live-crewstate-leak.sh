#!/usr/bin/env bash
# Live driver: a crew-state read restarts a stopped Herdr lab server while the
# fleet snapshot's FM_CREW_STATE_* overrides are set; inspect the real server
# process environment and a pane created afterwards.
# Usage: live-crewstate-leak.sh <firstmate-root> <label>
set -u
ROOT=$1; LABEL=$2
LAB="$ROOT/bin/fm-herdr-lab.sh"
S=$("$LAB" name "$LABEL")
echo "== code under test: $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo "$ROOT")"
echo "== lab session: $S"
T=$(mktemp -d /tmp/fm-crewleak.XXXXXX)
cleanup() { echo "== teardown"; "$LAB" teardown "$S" && echo "teardown ok"; rm -rf "$T"; }
trap cleanup EXIT
"$LAB" provision "$S" || exit 1
echo "provisioned"
"$LAB" stop "$S" >/dev/null && echo "lab server stopped"
sleep 1
herdr session list --json --session "$S" | jq -c --arg s "$S" '.sessions[]|select(.name==$s)|{name,running}'
# A captured fleet-snapshot pair, like fm-fleet-snapshot.sh passes for one call.
mkdir -p "$T/state" "$T/snap"
git -C "$T" init -q wt && git -C "$T/wt" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init && git -C "$T/wt" checkout -q -b fm/lrt
cat > "$T/snap/lrt.meta" <<META
window=$S:w1:p1
worktree=$T/wt
kind=ship
backend=herdr
harness=claude
META
: > "$T/snap/lrt.status"
start=$(date +%s)
out=$(env -u FM_HOME FM_STATE_OVERRIDE="$T/state" \
  FM_CREW_STATE_META_OVERRIDE="$T/snap/lrt.meta" FM_CREW_STATE_STATUS_OVERRIDE="$T/snap/lrt.status" \
  timeout 90 "$ROOT/bin/fm-crew-state.sh" lrt 2>&1); rc=$?
echo "== fm-crew-state.sh lrt -> rc=$rc elapsed=$(( $(date +%s) - start ))s (timeout 90 => rc 124)"
printf '%s\n' "$out" | head -5
herdr session list --json --session "$S" | jq -c --arg s "$S" '.sessions[]|select(.name==$s)|{name,running}'
pid=$(pgrep -f -- "herdr server --session $S" | head -1)
echo "== server pid: ${pid:-none} ($(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null))"
echo "== FM_* names in the live server environment:"
tr '\0' '\n' < /proc/$pid/environ | grep '^FM_' | cut -d= -f1 | sed 's/^/  /' | grep . || echo "  (none)"
echo "== HERDR_SESSION in server env: $(tr '\0' '\n' < /proc/$pid/environ | grep '^HERDR_SESSION=' )"
# A worker pane opened afterwards inherits the server environment.
ws=$("$LAB" run "$S" workspace create --label crewleak --no-focus)
pane=$(printf '%s' "$ws" | jq -r '.. | .pane_id? // empty' | head -1)
sleep 1
shell=$("$LAB" run "$S" pane process-info --pane "$pane" | jq -r '.. | .shell_pid? // empty' | head -1)
echo "== new pane $pane shell pid $shell; FM_* names in the pane shell environment:"
tr '\0' '\n' < /proc/$shell/environ | grep '^FM_' | cut -d= -f1 | sed 's/^/  /' | grep . || echo "  (none)"
