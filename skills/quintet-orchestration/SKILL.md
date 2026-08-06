---
name: quintet-orchestration
description: Orchestrate multiple coding-agent CLIs (Claude Code, OpenAI Codex, Google Gemini, GitHub Copilot, Qwen Code) as one fleet through the quintet entry point. Use proactively when running several of these AI CLIs at once, when spinning up a multi-agent CLI worker team in tmux, for fanning a single prompt out to many models, or when debating or reviewing across models. Trigger on "quintet", "run codex and gemini and copilot", "orchestrate CLI agents", "ask all the models", "AI debate", "multi-model review". Not for single-model edits or generic multi-agent frameworks unrelated to the quintet CLIs.
metadata:
  version: 0.1.0
  category: multi-agent-orchestration
  tags: quintet, orchestration, multi-model, router, fleet
---

# Quintet Orchestration

Quintet drives five coding-agent CLIs — `claude`, `codex`, `gemini`, `copilot`, `qwen` — through one entry point: `${CLAUDE_PLUGIN_ROOT}/bin/quintet`. It unifies two complementary execution models:

- **Team mode** (persistent): long-lived worker processes in tmux panes that autonomously edit files and coordinate. Best for *doing work in parallel*.
- **Fleet mode** (one-shot): a single prompt fanned out to several CLIs headless, with a reliability layer (circuit breaker + fallback). Best for *getting many perspectives*.

This skill is the **router**. It decides which mode fits the request and hands the deep procedure to `skills/quintet-team-runtime` or `skills/quintet-fleet-dispatch`.

## When to use

**Use when** the user names two or more of the quintet CLIs, says "quintet", or asks to run, compare, debate, or review across several AI models at once.

**Don't use when** the work is a single-model edit (call that CLI directly), or when "multi-agent" refers to an unrelated framework rather than these five CLIs. That distinction is the key decision this skill makes before doing anything else.

## Inputs and outputs

- **Input** this skill accepts: a natural-language task plus, optionally, an explicit provider list and a team/fleet preference.
- **Output format** it produces: for team mode, a launched-and-monitored team with a verified result; for fleet mode, a synthesized recommendation (consensus + disagreements + one call), never raw pasted blocks.

## First step, every time

Run the doctor so you only route to providers that are actually ready:

```bash
${CLAUDE_PLUGIN_ROOT}/bin/quintet doctor
```

This returns a per-provider readiness line. Never claim a provider ran if `doctor` shows it unauthenticated or missing. `qwen` commonly shows `auth=none` until the user runs `qwen` once to trigger OAuth.

**If doctor shows zero ready providers**, stop — there is nothing to orchestrate. Tell the user exactly which CLIs need installing or authenticating and wait until at least one is ready. Don't launch a team or fleet against an empty pool, and don't report an empty result as success.

### Reading doctor output

The human-readable form is one line per provider. A machine-readable form is available for scripting and is the contract other tools depend on:

```json
{
  "providers": [
    { "name": "claude",  "installed": true,  "auth": "ok",   "ready": true },
    { "name": "codex",   "installed": true,  "auth": "ok",   "ready": true },
    { "name": "gemini",  "installed": true,  "auth": "ok",   "ready": true },
    { "name": "copilot", "installed": true,  "auth": "ok",   "ready": true },
    { "name": "qwen",    "installed": true,  "auth": "none", "ready": false }
  ],
  "ready_count": 4
}
```

Build your pool from entries where `ready` is `true`. A provider with `auth=none` is installed but unauthenticated — name it to the user as a one-time fix, don't treat it as broken.

## Choosing the mode

| The user wants… | Use | Command |
| --- | --- | --- |
| Parallel implementation / refactor / build across agents | **team** | `quintet team <spec> "<task>"` |
| A quick second/third opinion on a question | **fleet/consult** | `quintet consult "<q>" [providers]` |
| Models to argue and converge | **debate** | `quintet debate "<q>" [providers]` |
| Multi-model code review of a diff/file | **review** | `quintet review "<target>" [providers]` |

The tradeoff: team mode is powerful but edits real files and costs more setup; fleet mode is cheap, read-only, and one-shot. Prefer fleet for decisions and team for production work.

The single question that resolves almost every routing decision: **does the request produce file edits, or opinions?** Edits → team. Opinions, decisions, reviews → fleet. If the user is ambiguous ("get the models to improve this module"), ask whether they want the models to *write the changes* (team) or *propose them* (fleet).

## Usage

Route a parallel build to a team (distinct subtask per worker, in spec order):

```bash
BIN="${CLAUDE_PLUGIN_ROOT}/bin/quintet"
$BIN team 2:codex,1:gemini,1:qwen "build the export feature" \
    --name export --cwd ./repo \
    --tasks "implement serializer in src/export/||add tests in tests/export/||write docs||audit edge cases"
```

Fan a question out for perspectives, then synthesize:

```bash
$BIN consult "Best way to dedupe a 10M-row stream in Rust?" claude,codex,gemini
```

Run an argue-and-converge debate, or a cross-model review of a diff:

```bash
$BIN debate "gRPC or REST for this internal service?"
$BIN review "$(git diff HEAD~1)" claude,gemini,copilot
```

A worker reports progress to a shared taskboard you poll — the lines look like:

```text
[w1-codex] implemented CSV serializer, 3 tests passing
[w2-gemini] researched edge cases; flagged UTF-8 BOM handling
[w1-codex] DONE
```

## What this router does and does not do

This skill **decides and hands off** — it does not run the team or fleet procedure itself. Keeping that boundary clean is the whole point of having a router:

- **Does**: check readiness, classify the request (edits vs opinions), pick the mode, and delegate to the owning skill.
- **Does not**: drive the launch/monitor/verify poll loop (that's `skills/quintet-team-runtime`), or run the debate rounds and fallback logic (that's `skills/quintet-fleet-dispatch`).

A common request spans both: *decide cheaply with fleet, then build with team*. The router sequences that handoff but lets each procedure skill own its mechanics. A full fleet-then-team walkthrough (design debate → scoped team build) is in [references/orchestration-details.md](references/orchestration-details.md).

## Team decomposition

Team workers share **one working directory** and can clobber each other. Before launching, split the task into file- or concern-scoped subtasks so no two workers own the same files, then match providers to strengths. The spec syntax (`N:provider` tokens), full decomposition mechanics, and the provider→work mapping live in [references/orchestration-details.md](references/orchestration-details.md) and `skills/quintet-team-runtime`.

## Synthesizing fleet output

Fleet **collects** answers; it does not pick a winner. After `consult`/`debate`/`review`, *you* synthesize: state the consensus, surface disagreements (and which model held which view), and give the user one recommendation with reasoning. For debates, weigh the round-2 refined positions.

### What good synthesis looks like

Don't paste five blocks back. Turn raw answers into a decision:

```text
Consensus (3/3): token-bucket, Redis-backed, 429 + Retry-After on reject.
Disagreement: codex wants per-user buckets keyed on API token; gemini argues
  per-IP is enough and cheaper. claude sided with per-user for fairness.
Recommendation: per-user buckets (codex/claude view) — the fairness win
  outweighs the extra key cardinality at 5k rps. Ship Redis from day one;
  the in-memory shortcut breaks the moment you run two instances.
```

That is the deliverable: one paragraph the user can act on, with the dissent preserved so they can overrule you with full information.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `doctor` shows all providers `auth=none` | nothing authenticated | authenticate at least one CLI; do not launch against an empty pool |
| team workers corrupt each other's files | overlapping file ownership | re-decompose by directory/module so each worker owns distinct paths |
| fleet returns fewer answers than providers | circuit breaker open or transient failure | expected — a `falling back → <other>` line means reliability kicked in |
| `tmux is not installed` | team mode needs tmux | install tmux, or use fleet mode (no tmux required) |
| routed to team but user only wanted advice | misread edits-vs-opinions | when ambiguous, ask "write the change, or propose it?" before launching |

## FAQ

**Which mode for "review my PR with all the models"?** Fleet — `review` is read-only. Pass the diff: `quintet review "$(git diff main)"`.

**Can I run team and fleet at once?** Yes, but keep them separate invocations. A common flow is fleet-to-decide then team-to-build (see the worked example).

**What if only one provider is ready?** Fleet still works (it just won't have breadth); team still works (single-worker). Tell the user breadth is reduced and proceed, or suggest authenticating more CLIs.

**How many workers is too many?** Cap at 10. In practice 3–5 scoped workers beat 10 overlapping ones — decomposition quality matters more than worker count.

**Does quintet send my code anywhere unexpected?** Each CLI uses its own provider's API under its own auth. Quintet only shells out to the CLIs you have installed and authenticated; it adds no extra network destination.

## Routing edge cases

A few requests don't map cleanly to one mode. How the router decides:

- **"Improve this module with the models"** — ambiguous. Ask: write the change (team) or propose it (fleet)? Don't guess; the cost of guessing wrong is either wasted edits or a missing deliverable.
- **"Review it and fix what's broken"** — two modes in sequence: `review` (fleet) to find issues, then a `team` to fix them. Route the first half, hand off, then route the second.
- **"Ask all the models, then have the best one implement"** — fleet to decide, then a single-worker team (or just call that CLI directly). Breadth first, depth second.
- **Only one provider is ready** — both modes still function (single-voice fleet, single-worker team); tell the user breadth is reduced rather than blocking.
- **The user named a non-quintet framework** — this skill does not apply; don't force a quintet route onto unrelated "multi-agent" tooling.

## Provider quick reference

A fast mental model for who to reach for. The maintained, detailed mapping is in `skills/quintet-team-runtime/references/provider-strengths.md`; this is the one-glance version the router uses while deciding a team spec:

| Provider | Reach for it when… | In a team | In a fleet |
| --- | --- | --- | --- |
| `claude` | careful implementation, refactors, reasoning-heavy edits | primary implementer | strong all-round answerer |
| `codex` | fast code generation, well-specified tasks | primary implementer | concise, code-first takes |
| `gemini` | research, breadth, docs, long-context scans | docs / audit worker | the "have we missed something?" voice |
| `copilot` | an extra independent perspective | secondary worker | tie-breaker in a debate |
| `qwen` | free-tier bulk volume, low-stakes passes | cheap audit/volume worker | extra breadth at no cost |

Rule of thumb: spend your strongest providers on the work that writes code, and use the cheaper ones for read-and-report passes.

## Cost and latency notes

- **Fleet fans out in parallel**, so wall-clock time ≈ the slowest provider, not the sum. A `debate` is roughly twice a `consult` because it's two rounds.
- **Team workers run concurrently** too, but cold-start warmup (REPL boot) is paid once per worker at launch — budget a few seconds before tasks land.
- **Narrow the provider list** when you don't need full breadth; every extra provider is another API call billed to that provider's account.

## Guardrails

- Team mode edits real files autonomously. Confirm scope with the user before launching write-capable workers on an important repo.
- Max 10 workers per team. Keep it to as few as the decomposition needs.
- Always `quintet team shutdown <name>` when work is verified or abandoned — orphaned tmux sessions waste resources.

## Related skills

See also the two procedure skills this router delegates to:

- `skills/quintet-team-runtime` — persistent team lifecycle, coordination, and recovery.
- `skills/quintet-fleet-dispatch` — one-shot dispatch, debate rounds, review framing, fallback behavior.

## Detailed references

- Spec/provider syntax, decomposition mechanics, synthesis detail: [references/orchestration-details.md](references/orchestration-details.md)
- Mode decision tree (team vs fleet) at a glance: [assets/mode-decision.txt](assets/mode-decision.txt)
