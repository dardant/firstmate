#!/usr/bin/env bash
# Throwaway lab driver: relaunch a real Claude crewmate through fm-spawn.sh in an
# isolated fm-lab-* Herdr session, leaving it up for /config and /context probes.
set -u
ROOT=/home/dardan/.no-mistakes/worktrees/a2097c65a770/01M3CV3P25A01T9NN5G8ZA6G3S
STATE=${1:?state file}
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
SESSION=$("$ROOT/bin/fm-herdr-lab.sh" name autocompact)
fm_herdr_lab_prepare "$SESSION" || { echo "prepare failed"; exit 1; }
export HERDR_SESSION="$SESSION"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-autocompact.XXXXXX"); SCRATCH=$(cd "$SCRATCH" && pwd)
HOME_DIR="$SCRATCH/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/acw"
cat > "$HOME_DIR/data/acw/brief.md" <<EOF
# Task
## Captain's intent
Live probe fixture for worker auto-compaction.

## Firstmate spec
Reply with the single word READY and stop. Do not run any tools. Do nothing else.
EOF
PROJ="$SCRATCH/proj"; WT="$SCRATCH/wt"
mkdir -p "$PROJ"; git -C "$PROJ" init -q; printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b acw "$WT"
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || { echo "source herdr failed"; exit 1; }
CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT" launcher-home "$SESSION") || { echo "container_ensure failed"; exit 1; }
CONTAINER=${CONTAINER_RAW%%$'\t'*}; SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}; WORKSPACE_ID=${CONTAINER#*:}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-acw" "$WT" "$SEEDED_TAB_ID") || { echo "create_task failed"; exit 1; }
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
TARGET="$SESSION:$PANE_ID"
{
  echo "window=$TARGET"; echo "endpoint_task_id=acw"; echo "worktree=$WT"; echo "project=$PROJ"
  echo "harness=claude"; echo "kind=ship"; echo "mode=no-mistakes"; echo "yolo=off"
  echo "model=default"; echo "effort=low"; echo "backend=herdr"; echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"; echo "herdr_tab_id=$TAB_ID"; echo "herdr_pane_id=$PANE_ID"
} > "$HOME_DIR/state/acw.meta"
printf 'SESSION=%s\nSCRATCH=%s\nHOME_DIR=%s\nWT=%s\nTARGET=%s\nPANE_ID=%s\n' "$SESSION" "$SCRATCH" "$HOME_DIR" "$WT" "$TARGET" "$PANE_ID" > "$STATE"
env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" acw --relaunch --harness claude --model claude-haiku-4-5-20251001 --effort low 2>&1
echo "spawn exit=$?"
