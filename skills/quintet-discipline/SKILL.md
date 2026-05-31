---
name: quintet-discipline
description: Engineering discipline for multi-agent work — lock intent before building, write zero-context plans, and prove claims with fresh evidence before declaring done. Trigger when starting a multi-step task, writing an implementation plan, or about to claim work is complete/fixed/passing (especially after a quintet fleet/team run, where provider output may be hallucinated). Not for trivial single-action edits.
---

# Quintet Discipline

Three habits that keep multi-agent work honest. Distilled to the load-bearing parts; skip the ceremony on small tasks.

When orchestrating quintet providers, all three matter more, not less: a provider claiming success is not evidence, consensus is not correctness, and a synthesis file existing is not the same as it having content.

---

## 1. Verification Gate — evidence before claims

**Iron Law: no completion claim without fresh verification evidence run *this turn*.** If you didn't run the command now, you can't say it passes.

Before claiming any success:
1. **Identify** the command that proves the claim.
2. **Run** it fresh (not cached, not "last time").
3. **Read** full output — exit code, failure count.
4. **Verify** the output actually confirms the claim.
5. **Then** state the claim *with* the evidence.

| Claim | Requires | NOT sufficient |
|-------|----------|----------------|
| Tests pass | Test output, 0 failures | "should pass", prior run |
| Build succeeds | Build exit 0 | linter passed |
| Bug fixed | Original symptom reproduced → now gone | "code changed, should work" |
| Regression test real | Fails without fix → passes with fix | passes once |
| Subagent/provider done | `git diff` shows the change | the agent said "done" |
| Requirements met | Line-by-line check vs spec | tests pass |
| Security control works | Direct evidence the control itself responded | "no error", ambiguous "it worked", session/CF-Access confounds |

**Red flags — if you think any of these, stop and run the check:** "should work now" · "I'm confident" · "just this once" · "the linter passed" · "the agent said it worked" · "it's a small change".

After a quintet fleet/team run: confirm the output file exists *and* has real content (`wc -l`), check timestamps for staleness, and remember exit 0 means the script ran — not that the result is good.

---

## 2. Intent Contract — lock the goal before building

For any multi-phase task, capture intent up front so output can be validated against it (not against scope drift). Keep it lightweight — a few lines, not a form. Skip entirely for quick single actions.

Capture before starting:
- **Job statement** — what the user is actually trying to accomplish, plainly.
- **Success criteria** — "good enough" (minimum) and, if relevant, "exceptional".
- **Boundaries** — what this should NOT become (over-engineered, out of scope, off-architecture).
- **Constraints** — stakeholders, existing assets to build on, timeline, technical limits.

For substantial multi-session work, persist it to `.claude/session-intent.md` so it survives context loss. For a single session, holding it in the task list is enough.

At key decisions, sanity-check against it ("does this still serve the job statement?"). At the end, validate each criterion (met / partial / not) and each boundary (respected / violated) before reporting done.

---

## 3. Writing Plans — zero context, bite-sized

When asked for a *plan*, produce a plan — do not jump to implementation, and don't downgrade it to a vague outline because the task feels simple. Rationale and recaps belong in logs/notes, not the plan; a plan is strictly the steps.

Write as if the executor has zero context for the codebase. Document: which files to touch, the actual code, how to test, how to verify.

**Task granularity** — each task is ONE action (~2–5 min): "write the failing test", "run it to confirm it fails", "implement minimal code", "run to confirm pass", "commit". Not "add the feature".

Per task, give:
- **Exact paths** — `src/validators/email.ts` line 23, not "in the utils folder".
- **Complete code** — the actual snippet, not "add validation logic".
- **Exact commands + expected output** — `npm test path/spec.ts` → `PASS 3/3`.
- **TDD order** — test before implementation; commit after each green step.

| Use a plan when | Skip it when |
|-----------------|--------------|
| Multi-step feature (3+ tasks) | One-line bug fix |
| Uncertain scope (clarifies thinking) | Config tweak |
| Delegating to a subagent/provider (zero-context execution) | Single file read |
| Complex refactor | |

**Bottom line:** if an engineer with zero context can execute it, it's a plan. Otherwise it's an outline.

---

## Persona references

On-demand framing cards in `references/personas/` (zero always-on cost). Load one **only** when the task or the provider prompt you're about to write falls in its domain:

- **When auditing auth, secrets, input handling, or attack surface** → read [`references/personas/security-auditor.md`](references/personas/security-auditor.md).
- **When debugging deploys, networking, CI, or infra incidents** → read [`references/personas/devops-troubleshooter.md`](references/personas/devops-troubleshooter.md).
- **When isolating a regression or chasing a root cause** → read [`references/personas/debugger.md`](references/personas/debugger.md).

**Do NOT load** them for general implementation or planning work — they're reference prompts to shape one analysis, not registered agents and not always-on context.
