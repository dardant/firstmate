#!/usr/bin/env bash
# Stand up a real Claude 2.1.280 in an isolated tmux socket, parked on the imports dialog.
set -u
L=${L:?}
rm -rf "$L/home" "$L/cfg" "$L/fmhome" "$L/sock" "$L/wt-t1"
mkdir -p "$L/home/projects" "$L/cfg" "$L/fmhome/state" "$L/fmhome/data/t1" "$L/sock"
proj="$L/home/projects/proj"
git init -q -b main "$proj"
printf '# proj\n' > "$proj/README.md"
git -C "$proj" -c user.name=t -c user.email=t@t add -A
git -C "$proj" -c user.name=t -c user.email=t@t commit -qm init
printf 'fleet rules\n' > "$L/home/AGENTS.md"
printf '@AGENTS.md\n' > "$L/home/CLAUDE.md"
node -e '
const fs=require("fs");const [cfg,proj]=process.argv.slice(1);
fs.writeFileSync(cfg,JSON.stringify({hasCompletedOnboarding:true,theme:"dark",numStartups:5,
 projects:{[proj]:{hasTrustDialogAccepted:true}}},null,2));' "$L/cfg/.claude.json" "$proj"
printf '# brief for t1\n' > "$L/fmhome/data/t1/brief.md"
cat > "$L/fmhome/state/t1.meta" <<META
window=fmses:fm-t1
endpoint_task_id=t1
worktree=$proj
project=$proj
harness=claude
kind=ship
mode=no-mistakes
yolo=off
model=default
effort=default
META
TMUX_TMPDIR="$L/sock" tmux -f /dev/null new-session -d -s fmses -n fm-t1 -x 160 -y 50 -c "$proj" \
  "env HOME=$L/home CLAUDE_CONFIG_DIR=$L/cfg bash --norc -i"
sleep 0.5
TMUX_TMPDIR="$L/sock" tmux send-keys -t fmses:fm-t1 "cd $proj && claude" Enter
for i in $(seq 1 60); do
  if TMUX_TMPDIR="$L/sock" tmux capture-pane -p -t fmses:fm-t1 | grep -q 'Allow external CLAUDE.md file imports'; then echo "parked on dialog after ${i}x0.5s"; exit 0; fi
  sleep 0.5
done
echo "dialog never appeared"; TMUX_TMPDIR="$L/sock" tmux capture-pane -p -t fmses:fm-t1; exit 1
