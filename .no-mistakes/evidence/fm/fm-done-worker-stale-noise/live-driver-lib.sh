# Live driver helpers: real fm-watch.sh + real fm-wake-drain.sh against a Herdr lab.
WT=/home/dardan/.no-mistakes/worktrees/a2097c65a770/01M3A3ZSHKXJFPH7732ADCYTWD
TMP=$(cat /tmp/fm-live-finish.current); SESSION=$(cat $TMP/session)
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
lab() { "$WT/bin/fm-herdr-lab.sh" run "$SESSION" "$@"; }
ts() { date -u +%H:%M:%S; }
# new_home <dir> <task> <idsfile> <meta-extra> <status-text>
new_home() {
  local home=$1 task=$2 ids=$3
  rm -rf "$home"; mkdir -p "$home/state" "$home/config" "$home/data"
  local ws tab pane; ws=$(jq -r .ws "$ids"); tab=$(jq -r .tab "$ids"); pane=$(jq -r .pane "$ids")
  { echo "window=$SESSION:$pane"; echo "endpoint_task_id=$task"; echo "harness=claude"
    printf '%b' "$4"
    echo "backend=herdr"; echo "herdr_session=$SESSION"; echo "herdr_workspace_id=$ws"
    echo "herdr_tab_id=$tab"; echo "herdr_pane_id=$pane"; } > "$home/state/$task.meta"
  printf '%b' "$5" > "$home/state/$task.status"
}
# firstmate_loop <root> <home> <secs> <log> [env...]: run the watcher as firstmate
# does - block, take the wake, drain+ack it, restart - for <secs>, logging each wake.
firstmate_loop() {
  local root=$1 home=$2 secs=$3 log=$4; shift 4
  local end=$(( $(date +%s) + secs )) pid out err seq gen
  while [ "$(date +%s)" -lt "$end" ]; do
    out=$(mktemp)
    env PATH="$TMP/fakebin:$PATH" FM_HOME="$home" FM_POLL=2 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_HOME_SUMMARY_INTERVAL=999999 "$@" \
      "$root/bin/fm-watch.sh" > "$out" 2>>"$log.stderr" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null && [ "$(date +%s)" -lt "$end" ]; do sleep 0.5; done
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
      echo "$(ts) watcher still blocking at window end (no wake)" >> "$log"
    else
      wait "$pid" 2>/dev/null
      echo "$(ts) WAKE: $(tr '\n' ' ' < "$out")" >> "$log"
    fi
    rm -f "$out"
    # firstmate drains and acknowledges the queued wake before re-arming
    err=$(mktemp)
    FM_HOME="$home" "$root/bin/fm-wake-drain.sh" >/dev/null 2>"$err" || true
    seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation.*$/\1/p' "$err")
    gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
    [ -z "$seq" ] || FM_HOME="$home" "$root/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
    rm -f "$err"
  done
}
# redraw <pane> <secs> <every>: an idle finished pane that redraws - toggle a
# composer character, so each redraw is a new pane hash with nothing new said.
redraw() {
  local pane=$1 secs=$2 every=$3 end=$(( $(date +%s) + $2 )) on=0
  while [ "$(date +%s)" -lt "$end" ]; do
    sleep "$every"
    if [ "$on" = 0 ]; then lab pane send-text "$pane" "r" >/dev/null; on=1
    else lab pane send-keys "$pane" backspace >/dev/null; on=0; fi
  done
  [ "$on" = 0 ] || lab pane send-keys "$pane" backspace >/dev/null
}
