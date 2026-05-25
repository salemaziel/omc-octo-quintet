# Orchestration details

Expanded routing guidance for the quintet entry point. SKILL.md keeps the mode-selection matrix and guardrails inline; this file holds decomposition mechanics, spec syntax, and synthesis detail.

## Command spec syntax

- `<spec>` = comma-separated `N:provider` tokens, e.g. `2:claude,1:codex,1:qwen` (counts of each provider).
- `[providers]` = `all` (default) or a comma list, e.g. `claude,gemini,copilot`.

## How to decompose for team mode

Team workers share **one working directory** and can clobber each other. Before launching:

1. Split the task into file- or concern-scoped subtasks so no two workers own the same files.
2. Match providers to strengths — see [`quintet-team-runtime/references/provider-strengths.md`](../../quintet-team-runtime/references/provider-strengths.md).
3. Pass distinct subtasks with `--tasks "subtask1||subtask2||..."` (one per worker, in spec order). Without it, every worker gets the shared goal.

Then monitor with `quintet team status <name>` and `quintet team capture <name>` rather than assuming success. Read `.quintet/teams/<name>/taskboard.md` for worker self-reports. Full lifecycle, coordination, and recovery procedures live in the **`quintet-team-runtime`** skill.

## How to use fleet results

Fleet **collects** answers; it does not pick a winner. After `consult`/`debate`/`review`, *you* synthesize: state the consensus, surface disagreements, and give the user one recommendation with reasoning. Don't just paste the raw blocks. Debate rounds, review framing, and fallback behavior live in the **`quintet-fleet-dispatch`** skill.

## A full worked example: fleet-then-team

A single user request often maps to two phases — decide cheaply with fleet, then build with team. Example: *"Use quintet to add rate limiting to the API and have the models sanity-check the design first."*

**Phase 1 — decide (fleet).** Sanity-checking a design is read-only, so route to `quintet-fleet-dispatch`:

```bash
quintet debate "Token-bucket vs sliding-window rate limiting for a 5k-rps public API in Go?" claude,codex,gemini
```

Synthesize the round-2 positions into one recommendation (say: token-bucket, Redis-backed), noting the live disagreement (in-memory vs Redis under multi-instance deploys).

**Phase 2 — build (team).** With the design settled, hand off to `quintet-team-runtime`: decompose by file ownership and launch:

```bash
quintet team 1:codex,1:claude,1:gemini "implement token-bucket rate limiting" \
    --name ratelimit --cwd ./api \
    --tasks "limiter middleware in internal/ratelimit/||wire into internal/http/router.go||table tests in internal/ratelimit/limiter_test.go"
```

The router's job ends at *choosing the mode and handing off*. The procedure skills own the launch/monitor/verify loop and the synthesis duty.
