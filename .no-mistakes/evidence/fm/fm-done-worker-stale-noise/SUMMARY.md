# Live validation: parked finished worker stays quiet (fm/fm-done-worker-stale-noise)

Isolated Herdr lab `fm-lab-finishquiet-*` (herdr 0.9.0), real Claude Code 2.1.280 workers idle in lab panes,
real `bin/fm-watch.sh` + `bin/fm-wake-drain.sh` run as firstmate does (block -> take wake -> drain+ack -> re-arm),
each scenario in its own throwaway FM_HOME. Base = 5391df4 (git archive), head = ede3136. Driver: live-driver-lib.sh.

| Scenario | Base (5391df4) | Head (ede3136) |
|---|---|---|
| S1 PR ship `done` + `pr=` recorded, idle Claude pane redrawing every 10s, 90s | 9 `stale:` wakes | 0 stale wakes (5x "absorbed stale (finish already on record, crew parked)") |
| S2 scout `done` then crew-written `resolved [key=scope]`, stable idle pane, FM_STALE_ESCALATE_SECS=20, 90s | 4 `stale:` wakes (surface + escalations 1-3, demand-deep-inspection) | 0 stale wakes |
| S3 real `fm-send` follow-up steer after the recorded done; Claude acts, goes idle, log still ends on old done | - | 1 `stale:` wake (reopened, alarms) |
| S3b crew appends a new `done` after the follow-up, pane redrawing, 60s | - | 0 stale wakes |
| S4 PR ship `done` (implementation committed) with no `pr=` yet, pane redrawing, 60s | - | 6 `stale:` wakes (still alarms) |
| S5 Claude `/config` "Session recap" row | control launch without var: `true` | fm-spawn launch env: `false` |

Lab teardown rc=0; default Herdr session tripwire unchanged.
