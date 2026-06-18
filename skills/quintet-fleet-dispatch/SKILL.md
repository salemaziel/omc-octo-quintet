---
name: quintet-fleet-dispatch
description: Run one-shot multi-AI fleet dispatch with quintet — fan a single prompt to several coding-agent CLIs (claude/codex/gemini/copilot/qwen) in parallel, run a two-round cross-model debate, or get a multi-model code review, with circuit-breaker and fallback reliability. Use proactively when fanning a prompt out to several models, when running an AI debate, when seeking consensus, or for reviewing a diff across models. Trigger on "quintet fleet", "AI debate", "run a debate between models", "consult the models", "get consensus from the models", "multi-model review", "what do all the models think". Not for parallel file-editing work — use quintet-team-runtime.
---

# Quintet Fleet Dispatch

Fleet mode sends **one prompt** to several provider CLIs in **parallel, headless**, then renders every answer. It applies a reliability layer: transient failures (timeouts, 429s, 5xx) trip a per-provider circuit breaker and trigger a fallback to another ready provider; permanent failures (auth, 4xx) do not. State: `${QUINTET_HOME:-$HOME/.quintet}/provider-state/`.

## When to use

**Use when** you want several models' perspectives, a decision, a consensus, or a review of a diff — anything read-only and one-shot. **Don't use when** the task is to *produce* multi-file changes in parallel; that writes files and belongs to `skills/quintet-team-runtime`. The decision is simply: opinions (fleet) vs edits (team).

## Inputs and outputs

- **Input**: one prompt (a question, or a diff/file for review) plus an optional provider list.
- **Output format**: the command prints each provider's answer under a per-provider header with a status tag. It does **not** decide — it returns raw answers, and you synthesize them into one recommendation.

## Usage

```bash
BIN="${CLAUDE_PLUGIN_ROOT}/bin/quintet"

$BIN consult "Best approach to dedupe a 10M-row stream in Rust?"          # all ready providers
$BIN consult "Is this regex catastrophic? ^(a+)+$" claude,codex            # chosen providers
```

```bash
$BIN debate  "Should we use gRPC or REST for this internal service?"       # 2-round cross-critique
$BIN review  "$(git diff HEAD~1)" claude,gemini,copilot                     # multi-model code review
```

`fleet` and `consult` are the same fan-out. `[providers]` defaults to `all`; pass a comma list to narrow. Output arrives under per-provider headers with a status tag:

```text
== claude [0:ok] ==
Use a streaming hash set keyed on a 64-bit fingerprint…

== codex [0:ok] ==
Prefer external merge-sort + dedupe if memory-bound…

== gemini [124:timeout] falling back → copilot ==
```

## What each mode produces

| Mode | Rounds | Produces |
| --- | --- | --- |
| `consult` / `fleet` | 1 | independent answers side by side |
| `debate` | 2 | round-1 positions, then cross-critique and refinement |
| `review` | 1 | severity-ranked findings per model for a diff/file |

The tradeoff: `debate` costs two full fan-outs but surfaces where models change their minds — use it when a decision is contested, and plain `consult` when you just want breadth.

## Your job after dispatch: synthesize

Fleet **collects**; it does not decide. After the command returns, you must:

1. Summarize where the models **agree** (high-confidence signal).
2. Surface where they **disagree** and why — disagreement marks the risky/uncertain parts.
3. Give the user **one recommendation** with reasoning, not five pasted blocks.

For `debate`, base the synthesis on the **round-2** refined positions, and explicitly note any point that stayed contested.

### What good synthesis looks like

Given three answers to "gRPC or REST?", don't paste them — resolve them:

```text
Consensus (3/3): for an internal, high-throughput, strongly-typed service, gRPC wins.
Disagreement: gemini flags gRPC's browser/debugging friction; codex and claude
  judge that irrelevant for service-to-service traffic.
Recommendation: gRPC, with a thin REST/JSON gateway only if a browser client
  ever needs in. Ship the .proto contract first so both sides can codegen.
```

That paragraph is the deliverable. The raw blocks are scaffolding you throw away.

## Machine-readable output

For scripting, `--json` emits a structured result you can post-process (e.g. to count agreement automatically):

```json
{
  "mode": "consult",
  "prompt": "Best approach to dedupe a 10M-row stream in Rust?",
  "answers": [
    { "provider": "claude", "status": "ok",      "exit": 0,   "text": "Streaming hash set…" },
    { "provider": "codex",  "status": "ok",      "exit": 0,   "text": "External merge-sort…" },
    { "provider": "gemini", "status": "timeout", "exit": 124, "fallback": "copilot" }
  ]
}
```

The `status`/`exit` pair tells you which answers are trustworthy; a `fallback` field marks where reliability kicked in.

## Before you dispatch

Run the doctor first so you know who's in the pool — providers with `auth=none` or an open circuit breaker are skipped silently:

```bash
${CLAUDE_PLUGIN_ROOT}/bin/quintet doctor
```

**If zero providers are ready**, fleet has nothing to fan out to: tell the user which CLIs need authenticating (commonly `qwen`, via one interactive run) and stop, rather than reporting an empty result as success.

## A full worked example

The user asks: *"Have the models review this migration script for foot-guns."* That's read-only and one-shot — a textbook `review`.

**1. Check the pool.** `quintet doctor` shows claude/codex/gemini ready, qwen `auth=none`. Use the three ready ones.

**2. Dispatch the review** with the diff as the target:

```bash
$BIN review "$(git diff main -- migrations/0007_add_indexes.sql)" claude,codex,gemini
```

**3. Read the per-model findings.** Each returns severity-ranked items. claude and codex both flag that `CREATE INDEX` without `CONCURRENTLY` locks the table; gemini additionally notes the migration isn't wrapped to be reversible.

**4. Synthesize into one verdict:**

```text
Blocking (2/3): CREATE INDEX locks the table on a live DB — use CONCURRENTLY
  and move it out of the transaction.
Worth fixing (1/3): add a paired down-migration so the change is reversible.
Recommendation: rewrite with CONCURRENTLY + a down-migration before merge.
```

The user gets a go/no-go, not three walls of text. That triage is the value fleet adds over asking one model.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| a provider is missing from the output | `auth=none` or open circuit breaker | `doctor` first; authenticate it or wait out the breaker cooldown |
| `falling back → <other>` in the log | transient failure on the first provider | expected behavior — the fallback's answer is appended |
| every provider times out (exit 124) | prompt too large, network slow, or a provider exploring the repo instead of answering | raise `QUINTET_<PROVIDER>_TIMEOUT` / `QUINTET_TIMEOUT`; the advisory preamble already instructs providers not to explore files (guidance, not a hard block) |
| empty result, no answers | zero providers ready | authenticate at least one CLI before dispatching |
| breaker open before a run even starts | stale failures from a prior session | fixed by `QUINTET_CB_FAILURE_WINDOW_SECS` windowing; clear leftover state with `rm -f "${QUINTET_HOME:-$HOME/.quintet}/provider-state/<p>.cooldown"` |
| breaker keeps reopening | a provider is genuinely down | lower `QUINTET_CB_FAILURE_THRESHOLD` to fail fast and route around it |
| debate round 2 fails with exit 126 | (historical) round-1 output too large for a single argv | fixed — round 2 now folds in only clean, length-capped successful answers |

## FAQ

**`consult` vs `debate` — when is the extra round worth it?** Use `debate` when the decision is contested or expensive to reverse; the round-2 cross-critique is where a model concedes or hardens. For a quick breadth check, `consult` is half the cost.

**Can I review a whole file instead of a diff?** Yes — pass the file contents or a description as the target. Diffs just keep the review focused on what changed.

**Why did one model not answer?** Either it was unauthenticated (`doctor` would show `auth=none`) or its circuit breaker was open from prior failures. The status tag in the output tells you which.

**Does fleet edit files?** Never. Fleet is strictly read/advisory. If you want changes written, that's team mode (`skills/quintet-team-runtime`).

## When NOT to use fleet

- For *doing* multi-file work in parallel, use **team mode** (`skills/quintet-team-runtime`) — fleet is read/advisory and one-shot.
- For a single model, just call that CLI directly; fleet's value is breadth + reliability across several.

## Picking providers per question

Fleet's value is breadth, but the *right* breadth beats the *most* breadth. Match the panel to the question:

| Question type | Good panel | Why |
| --- | --- | --- |
| Architecture / design trade-off | claude, codex, gemini | reasoning depth + a research voice |
| "Is this code correct / safe?" | claude, codex | implementation-grade scrutiny |
| Broad "did we miss anything?" | gemini, qwen, copilot | cheap breadth catches blind spots |
| Contested decision (use `debate`) | claude, codex, gemini | strong models that will actually push back |

Omit the provider list to use everyone ready; narrow it when a question doesn't need five voices.

## Reliability tuning recipes

The circuit breaker and timeouts are there so one flaky provider can't stall the panel. Common adjustments:

- **A provider is consistently slow on big diffs** → raise `QUINTET_<P>_TIMEOUT` for just that provider rather than the global timeout.
- **A provider keeps half-failing** → lower `QUINTET_CB_FAILURE_THRESHOLD` so its breaker opens fast and fleet routes around it via fallback.
- **You're iterating quickly and don't want long cooldowns** → shorten `QUINTET_CB_COOLDOWN_SECS` so a recovered provider rejoins the pool sooner.

A `falling back → <other>` line is the system working as designed — not an error to debug.

## Key environment variables

Tune dispatch and reliability without editing the CLI:

| Var | Purpose | Default |
| --- | --- | --- |
| `QUINTET_TIMEOUT` | global one-shot timeout, seconds | 240 |
| `QUINTET_<P>_TIMEOUT` | per-provider one-shot timeout | inherits `QUINTET_TIMEOUT` |
| `QUINTET_CB_FAILURE_THRESHOLD` | transient failures before a provider's breaker opens | 3 |
| `QUINTET_CB_FAILURE_WINDOW_SECS` | only failures this recent count toward the threshold | 900 |
| `QUINTET_CB_COOLDOWN_SECS` | how long an open breaker stays open | 300 |
| `QUINTET_ADVISORY_PREAMBLE` | text-only framing prepended to every prompt (set empty to disable) | (no-explore instruction) |
| `QUINTET_ANSWER_CAP` | max chars of each answer folded into debate round 2 | 8000 |
| `QUINTET_FAIL_RENDER_CAP` | max chars of a failed provider's output shown when rendering | 1500 |
| `QUINTET_HOME` | state + debate-transcript root | `~/.quintet` |

`<P>` is the uppercase provider name (`CLAUDE`, `CODEX`, `GEMINI`, `COPILOT`, `QWEN`). Lower the threshold to fail fast on a flaky provider, or raise the timeout for large review diffs.

**Breaker note:** the threshold counts only transient failures inside `QUINTET_CB_FAILURE_WINDOW_SECS`, so failures from a previous session no longer pre-trip the breaker on a fresh run. If a breaker is stuck open from old state, clear it with `rm -f "${QUINTET_HOME:-$HOME/.quintet}/provider-state/<provider>.cooldown"` (or wait out the cooldown). The path follows `QUINTET_HOME` when you've overridden it.

## Related skills

See also:

- `skills/quintet-orchestration` — the router that picks fleet vs team and checks readiness.
- `skills/quintet-team-runtime` — the persistent, file-editing counterpart.

## Detailed references

- Per-mode mechanics, reliability tuning, and empty-pool recovery: [references/modes-and-reliability.md](references/modes-and-reliability.md)
- Annotated sample debate transcript: [assets/debate-output-example.txt](assets/debate-output-example.txt)
