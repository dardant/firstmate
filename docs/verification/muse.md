# Verification: the muse (Muse Code) crewmate adapter

Active empirical evidence for firstmate's muse adapter.
The skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts; this record owns how they were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Version | `Muse Code 0.1.0 (0.1.0-R708.1)`, build sha `427a430436` |
| Verified | 2026-08-05, extended 2026-08-06 with the credentialed multi-step smoke |
| Artifact | `muse-aarch64-macos`, sha256 `4290bfafa5bbb81a6fd493aaea12f848c789b1d22edfa0c4b849151deba3e70c` |
| Platform | macOS arm64 (Darwin 25.5.0) |
| Re-verified | `Muse Code 1.4.0 (1.4.0-R4302.1)`, build sha `aebe0c188b`, on 2026-09-27; see [Muse Code 1.4.0](#muse-code-140-verified-2026-09-27) |

The binary was fetched from the published channel and its checksum matched the published manifest before any run:

```
$ curl -sS 'https://api.meta.ai/muse-code/channels/muse-stable'
{"channel":"muse-stable","version":"0.1.0-R708.1",...,"state":"public","min_version":null}

$ shasum -a 256 muse-bin
4290bfafa5bbb81a6fd493aaea12f848c789b1d22edfa0c4b849151deba3e70c  muse-bin
```

Every run below used an isolated `XDG_CONFIG_HOME` and `XDG_DATA_HOME` in a scratch directory and a throwaway git workspace, driven through tmux the way firstmate drives a crewmate pane.
`install.sh` was deliberately bypassed, so no shell profile and no `~/.local/bin` entry on the host was touched.

## What the model provider limits

Live TUI and session behavior below was observed against the built-in `--provider echo` startup provider, except for the provider-authentication prompt.
The credential paths and unauthenticated wait were probed separately against the default `meta` provider.
Turn-boundary structure, the trust dialog, interrupt, exit, composer rendering, credential behavior, and the event-log schema are real and verified.
Busy-state behavior under a genuine multi-step, real-model tool loop was verified separately on 2026-08-06 against the default `meta` provider with a live model, and is recorded under [the credentialed multi-step smoke](#the-credentialed-multi-step-smoke-verified-2026-08-06).

## Verified facts

### Process identity

The published launcher `exec`s a version-suffixed binary, so the live process name changes on every auto-update:

```
$ grep -nE 'muse-bin|exec ' launcher.sh
969:  candidate="$work/muse-bin"
977:  target="$dir/muse-bin-$version"
1035:  printf '%s/muse-bin-%s\n' "$dir" "$version"
1135:  exec "$binary" "$@"
```

`ps -o comm= -p <pid>` returns the full executable path, whose basename is `muse-bin-<version>`.
That is why both `bin/fm-harness.sh` and `bin/backends/tmux.sh` match the anchored prefix `muse-bin-*` rather than an exact name, and why neither can rely on an install-path component: `~/.local/bin/muse-bin-<version>` contains no `muse` path component.
The Muse launch clears `CLAUDECODE`, `PI_CODING_AGENT`, `GROK_AGENT`, `FM_PI_HARNESS`, `CURSOR_AGENT`, and `CURSOR_INVOKED_AS` before the worker starts, which is the verified launch behavior rather than what detection depends on.
[Harness detection precedence](runtime-backends.md#harness-detection-precedence) owns why a retained foreign marker cannot override the versioned ancestry.

[`runtime-backends.md`](runtime-backends.md#agent-liveness-name-sources) owns the resulting tmux liveness verdict and its relationship to the portable decoy regression.

### Turn lifecycle

A two-turn session produced exactly two run brackets, the second closed by an Escape interrupt:

```
9  {"kind":"run","run_id":"d352a097-...","event":{"kind":"started","prompt":"hello from firstmate"}}
45 {"kind":"run","run_id":"d352a097-...","event":{"kind":"terminal","terminal":"completed","turn_duration_ms":8152}}
49 {"kind":"run","run_id":"b50dac92-...","event":{"kind":"started","prompt":"second turn to interrupt"}}
78 {"kind":"run","run_id":"b50dac92-...","event":{"kind":"terminal","terminal":"cancelled","reason":"cancelled during model step"}}
```

On 0.1.0 the log's first record carries the workspace binding key:

```
"payload_type": "runtime.session.metadata",
"payload": {"kind":"metadata","record":{"workspace_root":".../muselab/ws1","provider_id":"echo",...}}
```

The fold transitions live, sampled during a 25-second in-flight turn:

```
T+ 5s fold=busy
T+10s fold=busy
T+15s fold=busy
T+20s fold=busy
T+25s fold=busy
T+30s fold=settled
```

Two decoys were observed in real logs and are pinned by regressions in `tests/fm-muse-harness.test.sh`:
a nested `"record":{"kind":"terminal"}` cleanup-effect payload that is not a run terminal, and independent sub-agent run lifecycles under `subagent/<child-session-id>/session.jsonl`.
The same regression suite verifies that unique resolution is cached, a changed current-day main-session namespace restores ambiguity to unknown, a replacement spawn binding selects its fresh main log, missing cached logs fail closed, and cached sub-agent paths are rejected.

### Autonomy, trust, and sandbox

A fresh untrusted workspace shows the trust dialog with option 1 preselected:

```
Do you trust this workspace?
> 1  Trust and continue
  2  Quit
Use Up/Down or 1/2, then Enter. Esc quits.
```

`--yolo` suppresses it entirely and the status bar reports `echo · <workspace> · YOLO`.
This matters because approval and the sandbox are ON by default and `--sandbox-network` defaults to `proxy-only`, which the binary reports as requiring managed shell sandboxing - a crewmate needs ordinary git and network access.

### Credentials

`muse auth set --provider` accepts only `meta`.
An unauthenticated launch does not exit; it waits indefinitely:

```
  Sign in at this page:
    https://auth.meta.com/oauth/device/?code=DGXZ-NRPR
  Waiting for approval…
  Esc cancel
```

That is why `bin/fm-spawn.sh` preflights worker-reachable `META_API_KEY` or `<config>/muse/auth.json` and refuses before creating an endpoint.
A caller-only `META_API_KEY` is refused because a long-lived backend daemon does not inherit it, while the non-secret `XDG_CONFIG_HOME` and `XDG_DATA_HOME` roots are resolved to absolute paths before preflight and forwarding so the stored credential and session-log binding reach the same worker environment.

### Foreign personal context

The interactive TUI rejects the `exec`-only flag:

```
$ muse --no-foreign-personal-context --provider echo hi
invalid TUI options: error: unexpected argument '--no-foreign-personal-context' found
  tip: a similar argument exists: '--no-session-log'
```

`MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL` is the control that works in TUI mode.
Comparing the `context_block_diagnostic` block ids emitted by otherwise identical runs, with the operator's real `~/.claude` rules present and no project `AGENTS.md`:

```
base     blocks=rules_file,workspace_identity,security_mode,skills_catalog,session_identity,subagent_delegation
killon   blocks=workspace_identity,security_mode,skills_catalog,session_identity,subagent_delegation
kill1    blocks=workspace_identity,security_mode,skills_catalog,session_identity,subagent_delegation
```

Repeating the comparison with a project `AGENTS.md` present confirms the kill switch drops only the FOREIGN rules:

```
a4base   blocks=rules_file,workspace_identity,security_mode,skills_catalog,session_identity,subagent_delegation
a4kill   blocks=rules_file,workspace_identity,security_mode,skills_catalog,session_identity,subagent_delegation
```

The `tui.foreign_context_notice_shown` flag in `settings.json` suppresses only the notice, never the loading, so a quiet later launch is not evidence of a clean context.

### Composer rendering

Captured with `tmux capture-pane -p -e`:

```
^[[38;2;90;160;255m^[[48;2;38;56;84m⟩ ^[[38;2;204;211;219mhello from firstmate^[[39m
^[[0m^[[38;2;90;160;255m⟩ ^[[39m
```

Prompt glyph `⟩` (U+27E9) at luminance ~149.9 against the 128 default ghost threshold; typed text at ~209.8.
After a single Escape the interrupted prompt is restored into the composer at the same bright ~209.8, and `C-u` clears it.

## The credentialed multi-step smoke (verified 2026-08-06)

This was the one item deferred until a `META_API_KEY` was available, because it is what decides whether a settled log may classify `idle`.
An open run was always positive proof of a turn in flight, but a settled log only proves no run is open at that instant, so the classifier held idle behind an opt-in in case a real turn spanned several runs.
The smoke below answered that: one run brackets a whole multi-step turn, and an Escape interrupt closes that run with `terminal=cancelled` rather than leaving the turn to continue in another run.
The credentialed result gives a settled Muse log the same idle trust as the Claude and Pi push sources, so the opt-in was removed and `bin/fm-busy-lib.sh` classifies a settled log `idle` outright.
Muse auto-updates its vendor binary underneath the fleet, firstmate normalizes the versioned process identity to the `muse` harness before busy classification, and the session log's own metadata carries semver `0.1.0` plus a build SHA that cannot be matched to that normalized identity.
A verified-build allowlist against this coarse identity would be false precision because it could not distinguish the running build, as well as a maintenance treadmill against the auto-updating binary.

Both runs below used the default `meta` provider with model `muse-spark-1.2-contributor`, on a real firstmate-launched crewmate pane, authenticated through the stored `~/.config/muse/auth.json` written by `muse auth set --provider meta --api-key-stdin` so the key never entered `argv`.

### One turn stays inside one run

A single 8-step tool loop (shell, file reads, a file write, a shell append) ran as one submitted turn in session `629b3bc1-5dd7-4a0d-a901-69701850922c`, log `~/.local/share/muse/sessions/2026/08/06/629b3bc1-5dd7-4a0d-a901-69701850922c/session.jsonl`.
The whole 828-record turn is bracketed by exactly one run pair, 23 tool batches deep:

```
$ grep -cE '"kind":"run","run_id":"[^"]*","event":\{"kind":"started"' session.jsonl
1
$ grep -cE '"kind":"run","run_id":"[^"]*","event":\{"kind":"terminal"' session.jsonl
1
$ grep -c '"payload_type":"tool_batch.effect.started"' session.jsonl
23

10  {"kind":"run","run_id":"db5869ed-...","event":{"kind":"started","prompt":"...launch-brief..."
827 {"kind":"run","run_id":"db5869ed-...","event":{"kind":"terminal","terminal":"completed",
      "reason":null,"turn_duration_ms":75243,"time_to_first_token_ms":69583,"eot_gate_ms":3907}
```

Scope the count to `"kind":"run"` as above.
A bare `grep -c '"event":{"kind":"started"'` returns 56 on the same log, because every tool batch effect reuses that inner event shape.

### Busy sampling and interrupt

Session `e4e0b4f4-38d0-46dc-b669-dfb5de92e0e0` sampled the fold while a multi-step turn was in flight, then interrupted it with Escape mid tool loop.
Five consecutive samples of `fm_busy_muse_run_state` on the bound log returned `busy`, and `fm_busy_classify` returned `busy muse-session-log` for the same samples; the fold settled immediately after the interrupt.
Its run closed as cancelled rather than staying open:

```
10  {"kind":"run","run_id":"a098d532-...","event":{"kind":"started","prompt":"...launch-brief..."
103 {"kind":"run","run_id":"a098d532-...","event":{"kind":"terminal","terminal":"cancelled",
      "reason":"cancelled during model step","turn_duration_ms":7849}
```

That is the same terminal shape the `echo`-provider interrupt produced, now confirmed against a live model mid tool loop.

`tests/fm-muse-harness.test.sh` pins the resulting classifier behavior: a log settled by either terminal reads `idle`, an open run reads `busy`, and only a resolution failure reads `unknown`.

## Muse Code 1.4.0 (verified 2026-09-27)

Every live check below ran on Linux x86_64 under WSL2 (kernel 6.18.33.2-microsoft-standard-WSL2) with the default `meta` provider and model `muse-spark-1.3-contributor` at `low` effort, unless it names the `echo` provider.
The worker was spawned through the real `bin/fm-spawn.sh` with `--harness muse --backend herdr` into an isolated Herdr 0.9.0 lab session created by `bin/fm-herdr-lab.sh`, with a scratch Firstmate home and project.

### Session log shape

The first line of every 1.4.0 `session.jsonl` is a retained permission frame, and the metadata record carrying `workspace_root` follows it:

```
line 1 {"retained_frame":"session_permission_transaction","frame_schema_version":1,...,"children":[{"child_index":0,"record_json":"{\"schema_version\":1,...}"},...]}
line 2 {...,"payload_type":"runtime.session.metadata","payload":{"kind":"metadata","record":{"build":{"semver":"1.4.0","sha":"aebe0c188b"},...,"workspace_root":"..."}}}
```

Run records moved `event` ahead of `kind` and `run_id`, and `kind` is no longer the first key inside a terminal `event`:

```
{...,"payload_type":"runtime.session","payload":{"event":{"kind":"started","prompt":"..."},"kind":"run","run_id":"94d0e69f-...",...}}
{...,"payload_type":"runtime.session","payload":{"event":{"eot_gate_ms":4443,"kind":"terminal","reason":null,"terminal":"completed",...},"kind":"run","run_id":"94d0e69f-...",...}}
```

Across the lab's sessions every retained frame was `session_permission_transaction`, and every record with neither `payload_type` nor `retained_frame` was a `retained_marker: omitted_live_only` stand-in for an ephemeral task delta, never a run record.
[`tests/captures/muse-1.4.0/README.md`](../../tests/captures/muse-1.4.0/README.md) records the four real lines the portable regression replays.

### Busy classification

On an idle worker the pre-fix classifier and the structural decoder disagreed on the same live task record:

```
unknown muse-session-log   <- pre-fix bin/fm-busy-lib.sh (first line has no workspace_root)
idle muse-session-log      <- bin/fm-busy-lib.sh with bin/fm-muse-session.cjs
```

During a 120-second foreground `sleep` tool call the pre-fix fold returned `none` for the open run while the structural fold returned `busy`.
On Herdr the classifier consults native agent state first, and native `working` covers streaming, so the session-log fold is what carries a long tool call.
A `bin/fm-control.sh <id> relaunch` wrote a new binding whose `prior_log` excluded the previous session, and the fold then bound the replacement's own log.
`muse resume <session-uuid> --yolo` in the same pane appended to that session's existing `session.jsonl`, and the fold read the resumed session `idle muse-session-log`.

### Control

`bin/fm-control.sh <id> interrupt` during the foreground tool call reported `cancel=confirmed` through the run-scoped terminal, and the fold then read `settled` with terminal `cancelled`.
An Escape that lands before any output restores the prompt into the composer, and `C-u` clears it to `empty`; after a tool had run, the composer stayed empty.
`bin/fm-control.sh <id> exit` sent `/exit`, and the pane printed `To continue this session, run muse resume <session-uuid>`.
`--yolo` launches showed no trust dialog, and a typed-plane `/plan ...` invocation submitted with exit 0 and printed `Loaded skill plan · built-in`.

### Composer and steering

Captured through `herdr pane read --format ansi`, the idle and typed composer rows are:

```
^[[0m^[[2m^[[38;2;103;108;116m──────...^[[0m
^[[0m^[[38;2;90;160;255m❯ ^[[0m
^[[0m^[[38;2;90;160;255m❯ ^[[0m^[[38;2;204;211;219mfix the login bug^[[0m
```

Herdr natively reports the pane as agent `muse`, and `fm_backend_composer_state` read the idle row `empty` and typed text `pending`.
Doorbells rang by `bin/fm-send.sh` submitted on an idle pane and mid-stream: twelve typed-and-Entered probes one to three seconds apart during a streaming turn all read `empty` afterwards and were processed in order after the turn.
The observed stall reproduced only when the text and its Enter reached Muse in the same read:

```
$ fm-herdr-lab.sh run <lab> pane send-text <pane> $': burst probe A - no reply needed\r'
❯ : burst probe A - no reply needed          (composer: pending)
$ fm-herdr-lab.sh run <lab> pane send-keys <pane> enter
❯ : burst probe A - no reply needed          (submitted as one line; composer: empty)
```

Muse dropped the coalesced carriage return rather than inserting a newline, so one later Enter submits the line intact.
That is the fleet report's shape: a loaded pane coalesces the ring's text and Enter, the single Enter is lost, and each later ring skips on the pending doorbell.
The ring now retries Enter while the composer stays proven pending; `test_ring_retries_a_swallowed_enter` in `tests/fm-task-inbox.test.sh` pins it against a real TTY stand-in that drops the first Enter the same way.

### Primary and secondmate capability probe

After a turn settled, a background `sleep 40` that the worker had started finished and Muse opened a new run on its own, with no input:

```
t=15 state=busy runs=2
t=30 state=settled runs=2
t=45 state=settled runs=2
t=60 state=busy runs=3      <- background command finished, model re-invoked
t=75 state=settled runs=3
```

The binary reads Claude-dialect hook configuration and carries the diagnostics `D97: asyncRewake: true handlers are unsupported` and `D97: model reawakening is unsupported`.
Its hook-event variant table, read with `strings` from `muse-bin-1.4.0-R4302.1`, has no plain `Stop` turn-end event:

```
HookEventKindSessionStartPreToolUsePermissionRequestPostToolUsePreLLMCallPostLLMCallPreCompactPostCompactSubagentStartSubagentStopSessionEndNotificationPostToolUseFailureStopFailurePostToolBatchInterruptSessionFork
```

That is static evidence, not a live hook run, but it matches the documented refusal of model reawakening: no hook found here can block or continue a turn end.
No Firstmate supervision protocol, turn-end guard, session-start, pre-tool, or delegation-guard integration exists for Muse, so neither the primary nor the secondmate role was exercised and both remain unverified.

### Live guards

```
$ FM_MUSE_SIGNALS_LIVE=1 tests/fm-muse-signals-live-e2e.test.sh
ok - Muse's real session protocol classifies busy in flight
ok - Muse's real session protocol emits one matched run bracket
ok - Muse's real bright prompt glyph classifies as an empty composer
$ FM_SEND_INBOX_LIVE_E2E=1 FM_SEND_INBOX_LIVE_HARNESSES=muse tests/fm-send-inbox-doorbell-live-e2e.test.sh
ok - muse (Muse Code 1.4.0 (1.4.0-R4302.1)): the doorbell reached a real worker, which acted and acked with the mv
$ FM_HARNESS_LIVENESS_DRIFT=1 tests/fm-harness-liveness-drift-live-e2e.test.sh
ok - harness liveness: muse Muse Code 1.4.0 (1.4.0-R4302.1) classifies alive
ok - harness detection: muse Muse Code 1.4.0 (1.4.0-R4302.1) is identified by the ancestry walk at comm strength
```

Before the signals guard learned 1.4.0's `❯`, its glyph check failed with `the final Muse prompt glyph has no effective truecolor foreground` while its composer verdict was already `empty`.

## Refreshing this record

Run both live guards after any muse upgrade, because the version-suffixed process name, session protocol, and styled composer are vendor-controlled surfaces:

```
FM_HARNESS_LIVENESS_DRIFT=1 bin/fm-test-run.sh tests/fm-harness-liveness-drift-live-e2e.test.sh
FM_MUSE_SIGNALS_LIVE=1 bin/fm-test-run.sh tests/fm-muse-signals-live-e2e.test.sh
```

The Muse signals guard requires a real `muse` binary and tmux but uses `--provider echo`, so it does not require `META_API_KEY` and cannot re-check the real-model turn-to-run relationship on its own.
The guard follows SGR state through the final prompt glyph and rejects both bright-then-dark and malformed-RGB negative controls before accepting that glyph's effective luminance.

muse's launcher can replace the running binary underneath the fleet, so an upgrade that changes the session protocol also invalidates the credentialed evidence above.
Repeat that smoke after a protocol-affecting upgrade: run one real multi-step tool-loop turn with credentials in place, confirm the run-scoped `started`/`terminal` counts are still exactly one each, and confirm an Escape still yields `terminal` with `cancelled`.
A build that ever split one turn across several runs would make a settled log ambiguous, which is a classifier change rather than a note in this file.

The portable counterparts that run in ordinary CI are `tests/fm-muse-harness.test.sh`, `tests/fm-tmux-agent-liveness.test.sh`, `tests/fm-composer-lib.test.sh`, and `tests/fm-composer-ghost.test.sh`.
