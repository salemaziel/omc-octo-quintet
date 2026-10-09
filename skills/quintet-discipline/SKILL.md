---
name: quintet-discipline
description: Verification and intent hygiene for multi-agent team and fleet execution. Use when decomposing tasks across quintet worker teams or verifying work produced by background providers (where workers self-report 'DONE' or outputs may be hallucinated/empty). Focuses on verifying real file artifacts and diffs instead of blindly trusting self-reports. Does NOT mandate running test suites for routine code edits, config tweaks, or version bumps.
---

# Quintet Discipline

Engineering hygiene for multi-agent orchestration — keeping multi-worker jobs coordinated and verifying real output artifacts without unnecessary overhead.

---

## 1. Proportional Verification — Artifacts Over Self-Reports

In multi-agent work (especially with persistent tmux teams like `quintet team` or background fleet dispatches), the primary failure mode is **blindly trusting a worker's self-reported success**. A provider CLI may print "Done!", update `taskboard.md` to `DONE`, or return exit code 0 while having hallucinated changes or written empty files.

**The core rule:** Verify the actual artifacts on disk, not the worker's chat message.

### Match verification to the change (Never force test suites blindly)

Verification must be proportional to the work done. **Never run full test suites, smoke tests, or heavy harness checks for trivial edits, version bumps, metadata, or documentation.**

| Scope of Change | Appropriate Check | What NOT to do |
|---|---|---|
| **Version bump / metadata / config** | `git diff` to confirm target string changed | **Do not** run smoke tests or test suites |
| **Documentation / notes** | Inspect file rendered or check `git status` | **Do not** run test commands |
| **Quintet worker team output** | Check modified files exist, have non-zero bytes (`wc -c`), and `git diff` shows actual code | Do not trust self-reported `DONE` without inspecting disk |
| **Fleet / debate synthesis** | Confirm synthesis output file exists and has substance (not 0 bytes or error trace) | Do not assume an exit 0 returned valid content |
| **Substantial logic / feature code** | Targeted checks if relevant and fast; only run test suites if specifically part of the task or requested | Do not repeatedly run expensive multi-CLI smoke tests unprompted |

---

## 2. Intent & Scope Separation — Preventing Worker Collision

When dispatching multiple workers (`quintet team`):

1. **File-level isolation**: Every worker must own distinct files or directories. Two workers writing to the same file will overwrite or clobber each other.
2. **Clear deliverables**: Define what files each worker is responsible for producing before spawning.
3. **Inspect before shutdown**: Check the files produced by workers before calling `quintet team shutdown <name>` — once the session is killed, pane histories and unsaved state are gone.

---

## 3. Pragmatic Plan Breakdown

When planning a multi-worker task:
- Break the work down by distinct files or modular subtasks (~2–5 minutes of focused work per worker).
- Avoid speculative ceremony: if a task is a single quick edit, just make the edit directly rather than spawning teams or creating heavy plans.
- When work is complete, verify the resulting diff and deliver it cleanly.
