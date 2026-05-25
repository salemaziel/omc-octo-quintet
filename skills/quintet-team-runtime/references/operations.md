# Team runtime operations

Detailed operational reference for persistent quintet teams. The SKILL.md keeps the lifecycle commands and safety-critical rules inline; this file holds the rest.

## Worker naming

Workers are auto-named `w<idx>-<provider>`, e.g. `w1-codex`, `w2-gemini`. Use these exact names for `capture`/`send`.

## Coordination model (file-based)

Each worker is instructed to append status lines `[w<idx>-<provider>] ...` to `taskboard.md`, ending with a `DONE` line. As the orchestrator you:

1. Poll `taskboard.md` and `team capture` to track progress.
2. Resolve cross-worker conflicts by `team send`-ing corrections.
3. Verify the actual files/tests yourself — the taskboard is self-reported, not ground truth.

## Provider strengths

See [provider-strengths.md](provider-strengths.md) for the canonical provider→work mapping used when assigning subtasks.

## Common failures

| Symptom | Cause | Fix |
| --- | --- | --- |
| `team '<n>' already running` | name collides with a live/stale session | `team status <n>`, then `shutdown <n> --force` if stale |
| worker window shows shell, not agent | launch cmd failed / CLI missing | `quintet doctor`; check the provider's install hint |
| task never submitted | warmup too short for cold start | raise `QUINTET_<PROVIDER>_WARMUP` and relaunch |
| `tmux is not installed` | no tmux on PATH | install tmux (team mode requires it; fleet mode does not) |
| every worker fails to launch / pool empty | no provider authenticated | `quintet doctor` and authenticate at least one CLI before relaunching — see the "no providers ready" recovery in `quintet-orchestration` |
