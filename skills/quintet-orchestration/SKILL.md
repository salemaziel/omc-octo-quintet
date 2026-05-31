---
name: quintet-orchestration
description: Orchestrate multiple coding-agent CLIs (Claude Code, OpenAI Codex, Google Gemini, GitHub Copilot, Qwen Code) as one fleet through the quintet entry point. Use proactively when running several of these AI CLIs at once, when spinning up a multi-agent CLI worker team in tmux, for fanning a single prompt out to many models, or when debating or reviewing across models. Trigger on "quintet", "run codex and gemini and copilot", "orchestrate CLI agents", "ask all the models", "AI debate", "multi-model review". Not for single-model edits or generic multi-agent frameworks unrelated to the quintet CLIs.
---

# Quintet Orchestration

Quintet drives five coding-agent CLIs — `claude`, `codex`, `gemini`, `copilot`, `qwen` — through one entry point: `${CLAUDE_PLUGIN_ROOT}/bin/quintet`.

**This skill is the router.** It does exactly four things: check readiness, classify the request (edits vs opinions), pick the mode, and hand off to the skill that owns the procedure. It does **not** run the launch/monitor/verify loop, the debate rounds, or the synthesis — those belong to the procedure skills. Keeping that boundary clean is the entire point of having a router.

The three execution modes it routes to:

| Mode | What it is | Best for | Owner skill |
| --- | --- | --- | --- |
| **fleet** | one prompt fanned out headless, read-only, with circuit-breaker + fallback | getting many perspectives | `quintet-fleet-dispatch` |
| **team** | long-lived tmux workers sharing one cwd, editing files | parallel work, shared dir | `quintet-team-runtime` |
| **headless-worktrees** | non-interactive workers, one git worktree each, then merged | parallel edits that must not collide | `quintet-headless-worktrees` |

## When to use

**Use when** the user names two or more of the quintet CLIs, says "quintet", or asks to run, compare, debate, or review across several AI models at once.

**Don't use when** the work is a single-model edit (call that CLI directly), or when "multi-agent" refers to an unrelated framework rather than these five CLIs. That distinction is the key decision this skill makes before doing anything else.

## First step, every time

Run the doctor so you only route to providers that are actually ready:

```bash
${CLAUDE_PLUGIN_ROOT}/bin/quintet doctor
```

This returns a per-provider readiness line. Never claim a provider ran if `doctor` shows it unready. Build your pool from the providers shown `ready=yes`.

For a parseable per-provider form, use `quintet providers`, which prints one line each:

```text
🟣 claude   installed=yes auth=oauth    ready=yes
🔴 codex    installed=yes auth=oauth    ready=yes
🟡 gemini   installed=yes auth=oauth    ready=yes
🟢 copilot  installed=yes auth=gh-cli   ready=yes
🔵 qwen     installed=yes auth=none     ready=no
```

A provider with `auth=none` is installed but unauthenticated — name it to the user as a one-time fix (commonly `qwen`, which needs one interactive `qwen` run for OAuth), don't treat it as broken. **If doctor shows zero ready providers**, stop — tell the user which CLIs need installing or authenticating and wait until at least one is ready; don't launch against an empty pool or report an empty result as success.

## Choosing the mode

The single question that resolves almost every routing decision: **does the request produce file edits, or opinions?**

| The user wants… | Route to | Command shape |
| --- | --- | --- |
| A quick second/third opinion on a question | **fleet** | `quintet consult "<q>" [providers]` |
| Models to argue and converge | **fleet** (debate) | `quintet debate "<q>" [providers]` |
| Multi-model code review of a diff/file | **fleet** (review) | `quintet review "<target>" [providers]` |
| Parallel implementation in a shared cwd (interactive) | **team** | `quintet team <spec> "<task>" --tasks "...||..."` |
| Parallel edits that must NOT collide (isolated, merged) | **headless-worktrees** | see `quintet-headless-worktrees` |

Edits → team or headless-worktrees. Opinions, decisions, reviews → fleet. Within "edits," pick by **isolation need**: if workers can safely share one directory, **team** (tmux REPL) is simplest; if they would clobber each other, must merge cleanly, or you want to avoid the interactive REPL warmup-swallow, use **headless-worktrees**.

If the user is ambiguous ("get the models to improve this module"), ask whether they want the models to *write the changes* (team/worktrees) or *propose them* (fleet). Don't guess — the cost of guessing wrong is either wasted edits or a missing deliverable.

**For the team↔fleet decision at a glance**, read [assets/mode-decision.txt](assets/mode-decision.txt) (a one-screen decision tree). Skip it once the edits-vs-opinions question already answers the route.

## Hand off — don't do the procedure here

Once you've picked the mode, delegate. The router's job ends at the handoff:

- **fleet** → `quintet-fleet-dispatch` owns dispatch, debate rounds, fallback behavior, and the synthesis duty (consensus + disagreements + one recommendation; never paste raw blocks).
- **team** → `quintet-team-runtime` owns the launch/monitor/steer/shutdown lifecycle and recovery.
- **headless-worktrees** → `quintet-headless-worktrees` owns worktree isolation, headless invocation, and merge/verify.

**Before composing a team spec**, read the canonical provider→work mapping in [`quintet-team-runtime/references/provider-strengths.md`](../quintet-team-runtime/references/provider-strengths.md) so you assign each subtask to the right model. **Do NOT load** it for a pure fleet/consult routing decision — fleet breadth doesn't need per-provider work assignment.

**For decomposition mechanics, spec syntax, and a full fleet-then-team walkthrough** (design debate → scoped team build), read [references/orchestration-details.md](references/orchestration-details.md) — but only when you're actually sequencing a two-phase request, not for a single-mode route.

## Routing edge cases

A few requests don't map cleanly to one mode:

- **"Improve this module with the models"** — ambiguous. Ask: write the change (team/worktrees) or propose it (fleet)?
- **"Review it and fix what's broken"** — two modes in sequence: `review` (fleet) to find issues, then a team/worktrees run to fix them. Route the first half, hand off, then route the second.
- **"Ask all the models, then have the best one implement"** — fleet to decide, then a single-worker team (or just call that CLI directly). Breadth first, depth second.
- **Only one provider is ready** — both modes still function (single-voice fleet, single-worker team); tell the user breadth is reduced rather than blocking.
- **The user named a non-quintet framework** — this skill does not apply; don't force a quintet route onto unrelated "multi-agent" tooling.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `doctor` shows all providers `auth=none` | nothing authenticated | authenticate at least one CLI; do not launch against an empty pool |
| routed to team but user only wanted advice | misread edits-vs-opinions | when ambiguous, ask "write the change, or propose it?" before launching |
| fleet returns fewer answers than providers | circuit breaker open or transient failure | expected — a `falling back → <other>` line means reliability kicked in |
| `tmux is not installed` | team mode needs tmux | install tmux, or use fleet / headless-worktrees (no tmux required) |

## Guardrails

- Team and worktrees modes edit real files autonomously. Confirm scope with the user before launching write-capable workers on an important repo.
- Max 10 workers per team; in practice 3–5 scoped workers beat 10 overlapping ones — decomposition quality matters more than count.
- Always `quintet team shutdown <name>` when work is verified or abandoned — orphaned tmux sessions waste resources.
- **Fleet fans out in parallel**, so wall-clock ≈ the slowest provider; a `debate` is ~2× a `consult` (two rounds). Narrow the provider list when you don't need full breadth — every extra provider is another billed API call.
- Quintet adds no network destination of its own: each CLI uses its own provider's API under its own auth.

## Related skills

- `quintet-fleet-dispatch` — one-shot dispatch, debate rounds, review framing, fallback, synthesis.
- `quintet-team-runtime` — persistent tmux team lifecycle, coordination, recovery.
- `quintet-headless-worktrees` — isolated worktree-per-agent parallel edits and merges.
- `quintet-discipline` — verify provider output before claiming done (a `DONE` line is not evidence).
