#!/usr/bin/env bash
# tests/fm-spawn-claude-transcript-live-e2e.test.sh - live guard
# (live-harness-optin family) for Claude transcript persistence.
#
# A Claude primary exports CLAUDE_CODE_CHILD_SESSION=1 into every tool shell,
# and a Herdr server started from that shell hands it to every pane. A real
# claude that inherits it shows "Transcript saving is off" and writes no
# transcript. This guard reproduces that end to end: it starts an isolated
# Herdr lab server from a marked environment, launches a real claude second
# mate through the real bin/fm-spawn.sh, and requires that the agent writes its
# transcript and never renders the transcript-off warning, failing with the
# installed Claude Code and Herdr versions. The portable regression is
# tests/fm-spawn-claude-child-session.test.sh; the dated result lives in
# docs/verification/runtime-backends.md "Claude transcript persistence".
#
# Run explicitly with FM_CLAUDE_TRANSCRIPT_LIVE_E2E=1. It submits one short
# prompt to the real Claude account, on the model named by
# FM_CLAUDE_TRANSCRIPT_LIVE_MODEL (default claude-haiku-4-5-20251001).
# Like every real claude spawn, it pre-registers workspace trust for its
# throwaway home in the operator's Claude store; it removes the transcript
# directory it caused.
#
# Every Herdr call, including calls made inside the production backend adapter,
# is routed through bin/fm-herdr-lab.sh, exactly as
# tests/fm-send-secondmate-marker-herdr-e2e.test.sh does.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"

fm_live_gate opt-in FM_CLAUDE_TRANSCRIPT_LIVE_E2E git herdr jq claude

LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=$("$LAB_HELPER" name claude-transcript)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-claude-transcript-e2e.XXXXXX")
SENDER_HOME="$TMP_ROOT/sender-home"
SECOND_HOME="$TMP_ROOT/secondmate-home"
FAKEBIN="$TMP_ROOT/fakebin"
ORIGINAL_PATH=$PATH
ID='transcript-claude-sm'
MODEL=${FM_CLAUDE_TRANSCRIPT_LIVE_MODEL:-claude-haiku-4-5-20251001}
TIMEOUT=${FM_CLAUDE_TRANSCRIPT_LIVE_TIMEOUT:-180}
VERSIONS="claude $(claude --version 2>/dev/null | head -1), herdr $(herdr --version 2>/dev/null | head -1)"
CLAUDE_STORE=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
TRANSCRIPT_DIR=

cleanup() {
  local rc=$?
  trap - EXIT
  if ! "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  [ -z "$TRANSCRIPT_DIR" ] || rm -rf "$TRANSCRIPT_DIR"
  # The spawn leaves a read-only git-hooks directory under the fixture state.
  fm_test_remove_tree "$TMP_ROOT"
  if [ -e "$TMP_ROOT" ]; then
    printf 'not ok - the fixture root was left behind: %s\n' "$TMP_ROOT" >&2
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT

mkdir -p "$SENDER_HOME/state" "$SENDER_HOME/data" "$SENDER_HOME/config" "$SENDER_HOME/projects" "$FAKEBIN"
touch "$SENDER_HOME/state/.last-watcher-beat"

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -euo pipefail
helper='$LAB_HELPER'
session='$SESSION'
real_path='$ORIGINAL_PATH'
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "\$session" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  [ "\${HERDR_SESSION:-}" = "\$session" ] || { echo "wrapper requires the isolated lab session" >&2; exit 98; }
  for arg in "\${args[@]}"; do
    case "\$arg" in
      --session|--session=*) echo "wrapper refused non-trailing session flag" >&2; exit 99 ;;
    esac
  done
fi
PATH="\$real_path" exec "\$helper" run "\$session" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

mkdir -p "$SECOND_HOME/bin" "$SECOND_HOME/data"
git -C "$SECOND_HOME" init -q
printf '# Firstmate\n\nThrowaway transcript-persistence test home. Do nothing else.\n' > "$SECOND_HOME/AGENTS.md"
printf '%s\n' "$ID" > "$SECOND_HOME/.fm-secondmate-home"
printf 'Reply with the single word TRANSCRIPTPROBE and then stop. Do not run any tools.\n' > "$SECOND_HOME/data/charter.md"
TRANSCRIPT_DIR="$CLAUDE_STORE/projects/$(cd "$SECOND_HOME" && pwd -P | sed 's/[^A-Za-z0-9]/-/g')"

# The lab server inherits this marked environment and passes it to its panes,
# which is the production carrier on Herdr.
CLAUDE_CODE_CHILD_SESSION=1 "$LAB_HELPER" provision "$SESSION" \
  || fail "could not provision the isolated Herdr lab session"
CLAUDE_CODE_CHILD_SESSION=1 PATH="$FAKEBIN:$ORIGINAL_PATH" FM_GATE_REFUSE_BYPASS=1 \
  FM_HOME="$SENDER_HOME" HERDR_SESSION="$SESSION" \
  "$ROOT/bin/fm-spawn.sh" "$ID" "$SECOND_HOME" --secondmate --harness claude \
  --model "$MODEL" --backend herdr >/dev/null \
  || fail "real claude secondmate spawn failed ($VERSIONS)"

META="$SENDER_HOME/state/$ID.meta"
TARGET=$(fm_backend_target_of_meta "$META")
PANE=${TARGET#*:}
case "$TARGET" in
  "$SESSION":w*:p*) : ;;
  *) fail "real secondmate metadata recorded an unexpected Herdr target: $TARGET" ;;
esac

screen=
transcript=
for _ in $(seq 1 "$TIMEOUT"); do
  screen=$("$LAB_HELPER" run "$SESSION" pane read "$PANE" --source visible 2>/dev/null || true)
  transcript=$(find "$TRANSCRIPT_DIR" -maxdepth 1 -name '*.jsonl' 2>/dev/null | head -1)
  case "$screen" in
    *'Transcript saving is off'*) break ;;
  esac
  if [ -n "$transcript" ] && [ "$(grep -c TRANSCRIPTPROBE "$transcript" 2>/dev/null)" -ge 2 ]; then
    break
  fi
  sleep 1
done

case "$screen" in
  *'Transcript saving is off'*)
    fail "the launched claude reports transcript saving off ($VERSIONS): $(printf '%s' "$screen" | grep 'Transcript saving')" ;;
esac
[ -n "$transcript" ] \
  || fail "the launched claude wrote no transcript under $TRANSCRIPT_DIR within ${TIMEOUT}s ($VERSIONS)"
pass "a claude launched from a marked Herdr pane keeps its transcript ($VERSIONS)"

# Divergence: the pane shell itself must have carried the marker, or the clean
# result above proved nothing about the launch.
"$LAB_HELPER" run "$SESSION" pane send-text "$PANE" '/exit' >/dev/null 2>&1 || true
"$LAB_HELPER" run "$SESSION" pane send-keys "$PANE" enter >/dev/null 2>&1 || true
sleep 5
# shellcheck disable=SC2016 # the pane shell, not this script, expands the marker
"$LAB_HELPER" run "$SESSION" pane send-text "$PANE" 'echo "PANEMARKER=${CLAUDE_CODE_CHILD_SESSION-unset}"' >/dev/null 2>&1 || true
"$LAB_HELPER" run "$SESSION" pane send-keys "$PANE" enter >/dev/null 2>&1 || true
seen=
for _ in $(seq 1 20); do
  sleep 1
  seen=$("$LAB_HELPER" run "$SESSION" pane read "$PANE" --source visible 2>/dev/null \
    | grep -o 'PANEMARKER=[a-z0-9][a-z0-9]*' | tail -1)
  [ -z "$seen" ] || break
done
assert_equals 'PANEMARKER=1' "$seen" \
  "the lab pane shell must carry the parent-session marker, or this guard proved nothing"
pass "the lab pane shell carried the marker that the launch removed"
