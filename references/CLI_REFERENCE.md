# Quintet CLI Reference

Complete reference for `quintet` CLI subcommands, options, and environment variables.

## Subcommands

- `quintet doctor`: Audit installed CLI binaries, OAuth states, and provider readiness pool.
- `quintet consult "<prompt>" [providers]`: One-shot fan-out across ready models with parallel execution.
- `quintet debate "<prompt>" [providers]`: Two-round argue-and-converge debate with cross-critique.
- `quintet review "<target>" [providers]`: Multi-model code review for git diffs or file targets.
- `quintet team <spec> "<task>" --name <name> --tasks "<t1>||<t2>"`: Spawn persistent tmux worker panes.
- `quintet status --name <name>`: Inspect active team worker taskboard and progress.
- `quintet stop <name>`: Gracefully terminate a running tmux worker team session.

## Provider Spec Syntax

Format: `<count>:<provider>,<count>:<provider>`
Example: `2:codex,1:agy,1:qwen` (or alias: `1:gemini`)
Available Providers: `claude`, `codex`, `agy` (alias: `gemini`), `copilot`, `qwen`.

## Environment Variables

| Variable | Purpose | Default |
|---|---|---|
| `QUINTET_TIMEOUT` | Global one-shot timeout in seconds | 240 |
| `QUINTET_<PROVIDER>_TIMEOUT` | Per-provider timeout (e.g. `QUINTET_CLAUDE_TIMEOUT`, `QUINTET_AGY_TIMEOUT`) | inherits `QUINTET_TIMEOUT` |
| `QUINTET_CB_FAILURE_THRESHOLD` | Circuit breaker failure threshold | 3 |
| `QUINTET_CB_FAILURE_WINDOW_SECS` | Failure window in seconds | 900 |
| `QUINTET_CB_COOLDOWN_SECS` | Circuit breaker cooldown seconds | 300 |
| `QUINTET_AGY_LAUNCH` | Custom launch command for agy team workers | `agy --dangerously-skip-permissions` |
| `QUINTET_AGY_TIMEOUT` | Custom timeout for agy one-shot calls | 240 |
| `QUINTET_AGY_WARMUP` | Initial worker warmup delay in seconds | 5 |
