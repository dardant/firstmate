# Live Herdr lab (fm-lab-donequiet-3328952-28282, herdr herdr 0.9.0, 2.1.280 (Claude Code)) - real bin/fm-watch.sh against a real idle Claude Code pane
# Pane redraws were real Claude re-layouts caused by herdr pane split/close with the lab viewer attached.

## BASE 7a014b44 - finished PR ship (done + pr= recorded, fm-crew-state: state: done · source: status-log · PR https://example.invalid/pull/7 checks green)
watch round 1 -> signal: /tmp/fm-donequiet.dHtqNt/base-run/state/prship.status 
watch round 2 -> stale: fm-lab-donequiet-3328952-28282:w1:p1 
watch round 3 -> quiet: split made while no viewer was attached, so Herdr did not relayout and the pane never redrew (no new hash)
watch round 4 -> check: rearm-resurface (the driver had killed the previous watcher; unrelated to this change)
watch round 5 -> stale: fm-lab-donequiet-3328952-28282:w1:p1 
watch round 6 -> stale: fm-lab-donequiet-3328952-28282:w1:p1 

## BASE 7a014b44 - finished scout, last lines resolved + note
watch round 1 -> signal: /tmp/fm-donequiet.dHtqNt/scout-base/state/scout1.status 
watch round 2 -> stale: fm-lab-donequiet-3328952-28282:w1:p1 
watch round 3 -> stale: fm-lab-donequiet-3328952-28282:w1:p1 

## BRANCH 842d07b - finished PR ship: round 1 = crew's own done report; round 2 = 90s with 3 real redraws
round 1 -> signal: /tmp/fm-donequiet.dHtqNt/new-run/state/prship.status
round 2 -> watcher still alive and quiet after 90s, wake queue empty
[2026-09-25T13:27:44-0400] absorbed stale (finish already on record, crew parked): fm-lab-donequiet-3328952-28282:w1:p1
[2026-09-25T13:27:59-0400] absorbed stale (finish already on record, crew parked): fm-lab-donequiet-3328952-28282:w1:p1
[2026-09-25T13:28:20-0400] absorbed stale (finish already on record, crew parked): fm-lab-donequiet-3328952-28282:w1:p1
[2026-09-25T13:28:41-0400] absorbed stale (finish already on record, crew parked): fm-lab-donequiet-3328952-28282:w1:p1

## BRANCH - finished scout (resolved + note after done): 90s with 3 real redraws
round 1 -> signal: /tmp/fm-donequiet.dHtqNt/scout-new/state/scout1.status
round 2 -> watcher still alive and quiet after 90s
[2026-09-25T13:30:06-0400] absorbed stale (finish already on record, crew parked): fm-lab-donequiet-3328952-28282:w1:p1
[2026-09-25T13:30:21-0400] absorbed stale (finish already on record, crew parked): fm-lab-donequiet-3328952-28282:w1:p1
[2026-09-25T13:30:40-0400] absorbed stale (finish already on record, crew parked): fm-lab-donequiet-3328952-28282:w1:p1
[2026-09-25T13:31:03-0400] absorbed stale (finish already on record, crew parked): fm-lab-donequiet-3328952-28282:w1:p1

## BRANCH - adversarial: same-hash absorbed scout, FM_PAUSE_RESURFACE_SECS=12; crew-state wrapper passes real verdict until flipped to 'state: failed · source: run-step · run failed'
phase 1 (not flipped, 25s): quiet; .stale-done marker refreshed 13:31:03 -> 13:32:28 by the recheck
phase 2 (flipped 13:32:46): stale: fm-lab-donequiet-3328952-28282:w1:p1
[2026-09-25T13:32:58-0400] finish on record no longer parked on recheck, reclassifying stale: fm-lab-donequiet-3328952-28282:w1:p1

## BRANCH - adversarial: firstmate steer enqueued after the recorded done, then a real redraw
steer record: schema=fm-task-inbox.v1 at=2026-09-25T17:33:12Z -- Also add a line to the PR description about the rollback plan.
-> stale: fm-lab-donequiet-3328952-28282:w1:p1

## BRANCH - control: same PR ship without pr= recorded in meta
round 1 -> signal: /tmp/fm-donequiet.dHtqNt/nopr-run/state/prship.status
round 2 -> stale: fm-lab-donequiet-3328952-28282:w1:p1
