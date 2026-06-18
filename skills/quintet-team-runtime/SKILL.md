---
name: quintet-team-runtime
description: Operate persistent quintet worker teams — spawn coding-agent CLIs (claude/codex/gemini/copilot/qwen) as long-lived tmux workers, distribute scoped subtasks, monitor, and shut down. Use proactively when running a multi-agent CLI team in tmux, when distributing work across AI workers, for building or refactoring in parallel, or when recovering a stuck or orphaned quintet team. Trigger on "quintet team", "tmux worker team", "parallel AI workers", "spawn agent workers", "run codex and gemini in parallel to build", "distribute subtasks across models". Not for one-shot multi-model questions — use quintet-fleet-dispatch.
---

# Quintet Team Runtime

A team is a **detached tmux session** named `quintet-<name>`, one window per worker (plus a `leader` log window). Workers are interactive agent CLIs that receive a task via `send-keys` and then work autonomously in the shared cwd. State lives in `${QUINTET_STATE_DIR:-$PWD/.quintet}/teams/<name>/` (`team.json`, `taskboard.md`).

Attach to watch live: `tmux attach -t quintet-<name>` (detach with `Ctrl-b d`).

## When to use

**Use when** you need several agent CLIs to *do work* in parallel — implementing, refactoring, testing, or auditing different parts of a repo at the same time. **Don't use when** you just want opinions or a review on one question; that one-shot, read-only case is `skills/quintet-fleet-dispatch`. The decision hinges on whether files get written (team) or not (fleet).

## Inputs and outputs

- **Input**: a team spec (`N:provider` tokens), a shared goal, and one scoped subtask per worker.
- **Output format**: each worker produces real file edits in the shared cwd plus self-reported status lines on the taskboard. The orchestrator's job is to verify those artifacts and report what actually landed.

## Usage

The lifecycle is four phases — launch, monitor, steer, tear down.

```bash
BIN="${CLAUDE_PLUGIN_ROOT}/bin/quintet"

# 1. Launch (distinct subtask per worker, in spec order)
$BIN team 2:codex,1:gemini,1:qwen "build the export feature" \
    --name export-feat --cwd /path/to/repo \
    --tasks "implement CSV serializer in src/export/||add unit tests in tests/export/||write docs in docs/export.md||audit edge cases and report to taskboard"
```

```bash
# 2. Monitor (poll; do not assume success)
$BIN team status export-feat
$BIN team capture export-feat            # all workers, last 40 lines each
$BIN team capture export-feat w1-codex 80
```

```bash
# 3. Steer a worker mid-flight
$BIN team send export-feat w2-gemini "skip the legacy path; focus on v2 API"
```

```bash
# 4. Tear down when verified
$BIN team shutdown export-feat           # keep state
$BIN team shutdown export-feat --force   # purge state too
$BIN team list                           # all running quintet teams
```

Workers are auto-named `w<idx>-<provider>` (e.g. `w1-codex`, `w2-gemini`); use these exact names for `capture`/`send`.

### The team manifest

`team.json` is the source of truth for a running team — read it to recover state after a disconnect or to script monitoring:

```json
{
  "name": "export-feat",
  "cwd": "/path/to/repo",
  "session": "quintet-export-feat",
  "started": "2026-05-25T04:30:00Z",
  "goal": "build the export feature",
  "workers": [
    { "name": "w1-codex",  "provider": "codex" },
    { "name": "w2-codex",  "provider": "codex" },
    { "name": "w3-gemini", "provider": "gemini" },
    { "name": "w4-qwen",   "provider": "qwen" }
  ]
}
```

Each worker object is `{"name","provider"}`; the per-worker subtask is recorded in the taskboard (`taskboard.md`), not the manifest. The `session` field is the tmux session to attach to.

If a session is orphaned (you lost the terminal), `team list` plus this file is enough to re-attach, capture, or shut it down cleanly.

## Reading the taskboard

Each worker appends status lines to `taskboard.md` and ends with a `DONE` line. Poll it alongside `team capture`:

```text
[w1-codex] serializer implemented in src/export/csv.rs
[w2-gemini] alt approach: stream rows to avoid buffering 10M rows
[w3-qwen] docs/export.md drafted
[w1-codex] DONE
```

Treat these as self-reported, not ground truth — read the real files and run the tests yourself before trusting a `DONE`. A copy-paste-ready taskboard skeleton lives in [assets/taskboard-template.md](assets/taskboard-template.md).

## Provider selection

Match each subtask to the provider best suited to it. Quick rule: Codex/Claude for implementation, Gemini for breadth and research, Copilot for an extra perspective, Qwen for free-tier bulk volume. The canonical, maintained mapping is in [references/provider-strengths.md](references/provider-strengths.md).

## A full worked example

The user wants a CSV export feature built in parallel. Walk the whole lifecycle:

**1. Decompose by ownership.** Four non-overlapping concerns: the serializer (`src/export/`), its tests (`tests/export/`), docs (`docs/`), and an edge-case audit (read-only, writes only to the taskboard). No two workers touch the same files — that is the rule that prevents corruption.

**2. Map providers to work.** Serializer → codex (strong implementer). Tests → a second codex worker. Docs → gemini (good prose/breadth). Audit → qwen (free-tier, fine for a read-and-report pass).

**3. Launch** with the `team` command above, then immediately `team capture export-feat` to confirm every REPL came up and accepted its task (not a bare shell prompt).

**4. Monitor in a poll loop.** Every ~30s: `team status`, skim `team capture`, read `taskboard.md`. When `w2-gemini` drifts into the legacy path, steer it: `team send export-feat w2-gemini "skip legacy; v2 API only"`.

**5. Verify, don't trust.** When the taskboard shows `DONE`, open `src/export/csv.rs`, run `cargo test export`, and confirm the docs exist. Only then `team shutdown export-feat`.

The discipline that makes this work: **scope by files, verify by artifacts.** Everything else is mechanics.

## Critical rules

- **File ownership**: never give two workers overlapping files. This is the #1 cause of corruption. Scope subtasks by directory/module.
- **Verify launch**: after starting, run `team capture` to confirm each agent REPL came up and accepted the task. Cold-start warmup is provider-specific (tune via `QUINTET_<PROVIDER>_WARMUP` seconds).
- **Autonomy flags**: defaults launch agents in **fully unattended** modes so they can write to the worktree without stopping for approvals — `claude --permission-mode bypassPermissions`, `codex --yolo`, `copilot --allow-all-tools`, `gemini --approval-mode yolo --skip-trust`, and `qwen --approval-mode yolo` with `GEMINI_CLI_TRUST_WORKSPACE`/`QWEN_CLI_TRUST_WORKSPACE=true` (qwen lacks `--skip-trust`, so the trust env is what actually unblocks its file writes). Anything less (e.g. `acceptEdits`) deadlocks workers on trust/permission gates with no human to dismiss them. Override per provider via `QUINTET_<PROVIDER>_LAUNCH` for stricter sandboxing — but only when a human is watching the panes.
- **Verify artifacts, not the taskboard**: the taskboard is self-reported; the files and tests are the proof.
- **No providers ready**: if `doctor` reports an empty pool, the launch fails — authenticate at least one CLI first (see `skills/quintet-orchestration`).

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `team '<n>' already running` | name collides with a live/stale session | `team status <n>`, then `shutdown <n> --force` if stale |
| worker window shows shell, not agent | launch cmd failed / CLI missing | `quintet doctor`; check the provider's install hint |
| task never submitted | warmup too short for cold start | raise `QUINTET_<PROVIDER>_WARMUP` and relaunch |
| `tmux is not installed` | no tmux on PATH | install tmux (team mode requires it; fleet mode does not) |
| worker hangs mid-task | model stalled or waiting on input | `team send` an interrupt, or `shutdown --force` and relaunch smaller |
| two workers edited the same file | overlapping ownership in the spec | re-decompose; never share a path between workers |

## FAQ

**Can I add a worker to a running team?** No — teams are fixed at launch. Shut down and relaunch with the new spec, or run a second small team for the extra work.

**Do workers see each other's output?** Not directly. They share a cwd and the taskboard; coordinate explicit dependencies by ordering subtasks or steering with `team send`.

**What happens to a worker that finishes early?** It idles in its REPL until shutdown. That's fine — it costs nothing but a tmux window.

**How do I keep the state after a run?** `team shutdown <name>` (without `--force`) preserves `team.json` and `taskboard.md` under `QUINTET_STATE_DIR` for later inspection.

**Is tmux really required?** Yes, for team mode — workers are persistent interactive sessions. If you can't install tmux, use fleet mode (`skills/quintet-fleet-dispatch`), which is headless.

## Scaling and worker count

More workers is not more throughput past a point — overlap and review overhead grow faster than parallelism helps.

- **1–2 workers**: a focused change with a clean split (impl + tests). Easiest to verify.
- **3–5 workers**: the sweet spot for a feature with naturally separate concerns (impl, tests, docs, audit). Most real teams live here.
- **6–10 workers**: only when the repo genuinely has that many non-overlapping modules. Past this you spend more time decomposing and verifying than you save.
- **Hard cap: 10.** The launcher refuses more; if you think you need them, your subtasks probably overlap and should be merged.

The bottleneck is almost never compute — it's *decomposition quality*. Three well-scoped workers that never touch the same file beat eight that fight over one.

## Sandboxing and autonomy

Workers launch in **fully unattended** modes by default so they can work without stopping for approvals — `claude --permission-mode bypassPermissions`, `codex --yolo`, `copilot --allow-all-tools`, `gemini --approval-mode yolo --skip-trust`, and `qwen --approval-mode yolo` (prefixed with `GEMINI_CLI_TRUST_WORKSPACE=true QWEN_CLI_TRUST_WORKSPACE=true`, since the qwen fork has no `--skip-trust` flag and would otherwise refuse to write in an untrusted directory). This is required, not merely convenient: a team worker has no human at its pane, so any mode that pauses on a trust or permission gate (e.g. `claude --permission-mode acceptEdits`) silently deadlocks the whole run. That is the right default for a scratch repo or a worktree, and the wrong one for a production checkout.

The one-shot fleet/debate path is deliberately the opposite: it runs each provider headless and read-only behind the advisory preamble (no file writes expected), so sandbox-default invocations there are fine — the unattended write-access flags above apply only to team workers that are actually doing work.

Tighten it per provider with `QUINTET_<P>_LAUNCH`, which overrides the entire launch command for that provider's workers:

```bash
# Run claude workers in a stricter mode for this team
export QUINTET_CLAUDE_LAUNCH='claude --permission-mode default'
$BIN team 2:claude "refactor auth" --name auth --cwd ./repo --tasks "...||..."
```

Safer still on an important repo: point `--cwd` at a `git worktree` or a branch checkout, so autonomous edits are isolated and trivially discarded if a worker goes wrong. Confirm scope with the user before launching write-capable workers on anything you can't cheaply revert.

## Recovering an orphaned team

If you lose the terminal or a session compacts mid-run, the team keeps running detached. Recover it:

```bash
$BIN team list                           # find the session by name
$BIN team status <name>                  # confirm it's still alive
tmux attach -t quintet-<name>            # watch live (Ctrl-b d to detach)
$BIN team capture <name>                 # or pull worker output headless
```

`team.json` + `taskboard.md` under `QUINTET_STATE_DIR` hold everything you need to decide whether to keep steering it or `shutdown --force`. Nothing is lost just because the controlling terminal went away.

## Key environment variables

Tune team behavior without editing the CLI:

| Var | Purpose | Default |
| --- | --- | --- |
| `QUINTET_STATE_DIR` | where team state (`team.json`, `taskboard.md`) lives | `$PWD/.quintet` |
| `QUINTET_<P>_WARMUP` | seconds to wait before injecting the task into a cold REPL | 5–6 |
| `QUINTET_<P>_LAUNCH` | the interactive launch command for that provider's workers | per provider |

`<P>` is the uppercase provider name (`CLAUDE`, `CODEX`, `GEMINI`, `COPILOT`, `QWEN`). Raise warmup when a worker's window shows a shell prompt instead of the agent at launch.

## Related skills

See also:

- `skills/quintet-orchestration` — the router that decides team vs fleet and handles readiness checks.
- `skills/quintet-fleet-dispatch` — the one-shot, read-only counterpart for questions and reviews.

## Detailed references

- Provider→subtask mapping: [references/provider-strengths.md](references/provider-strengths.md)
- Coordination model, worker naming, full failure table: [references/operations.md](references/operations.md)
- Taskboard skeleton to copy: [assets/taskboard-template.md](assets/taskboard-template.md)
