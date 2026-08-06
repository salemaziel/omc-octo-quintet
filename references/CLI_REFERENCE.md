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
Example: `2:codex,1:gemini,1:qwen`
Available Providers: `claude`, `codex`, `gemini`, `copilot`, `qwen`.

## Environment Variables

| Variable | Purpose | Default |
|---|---|---|
| `QUINTET_TIMEOUT` | Global one-shot timeout in seconds | 120 |
| `QUINTET_<PROVIDER>_TIMEOUT` | Per-provider timeout (e.g. `QUINTET_CLAUDE_TIMEOUT`) | 90-120 |
| `QUINTET_CB_FAILURE_THRESHOLD` | Circuit breaker failure threshold | 3 |
| `QUINTET_CB_COOLDOWN_SECS` | Circuit breaker cooldown seconds | 300 |
