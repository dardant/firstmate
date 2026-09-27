# Muse 1.4.0 session-log capture

`session.jsonl` owns the recorded Muse 1.4.0 session-log input for `test_retained_frames_and_reordered_events` in `../../fm-muse-harness.test.sh`.
It was captured on 2026-09-27 from a real Muse Code 1.4.0 (1.4.0-R4302.1, build sha `aebe0c188b`) worker on provider `meta` with model `muse-spark-1.3-contributor`, spawned through `bin/fm-spawn.sh` in an isolated Herdr lab session.
It is a replay input, not evidence that every composed scenario in that test was driven live.

## Capture provenance

The four lines are unchanged records from one real `session.jsonl`, in their original order:

| Line | Record | Shape it pins |
| --- | --- | --- |
| 1 | `retained_frame: session_permission_transaction` | The first line is a permission envelope whose real records are JSON strings under `children[].record_json`, not the session metadata |
| 2 | `runtime.session.metadata` | Metadata that carries `workspace_root` arrives second |
| 3 | `runtime.session` run `started` | `payload.event` precedes `payload.kind` and `payload.run_id`, unlike 0.1.0's field order |
| 4 | `runtime.session` run `terminal` with `terminal: completed` | The same run's close, with `kind` no longer the first key inside `event` |

The only substitution is the worker's scratch worktree path, replaced in `workspace_root` by the literal `MUSE_TEST_WORKSPACE`, which the test rewrites to its own disposable workspace.
Lines 3 and 4 are the run for a harmless probe prompt, chosen because its prompt text carries no local path.

## Replay limits

The test composes further cases around these lines: the synthetic cleanup-effect decoy, a retained frame that nests run records as JSON strings, a partial appended line, and a corrupt complete line.
Those compositions are controlled fixtures, not captured Muse output.
`../../../docs/verification/muse.md` owns the live evidence for busy and idle classification on this version.
