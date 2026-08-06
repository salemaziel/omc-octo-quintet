---
name: review
description: Runs a multi-model code review of a diff or target file across ready AI provider CLIs, synthesizing severity-ranked findings into a single go/no-go verdict. Use when reviewing code changes, auditing git diffs, checking security flaws, or getting multi-AI code reviews.
metadata:
  version: 0.1.0
  category: multi-agent-orchestration
  tags: quintet, review, code-review, git-diff, security-audit
---

# Quintet Multi-Model Code Review

Performs multi-perspective code reviews across ready AI provider CLIs for git diffs or file contents, consolidating findings into an actionable verdict.

## Workflow

1. **Target Preparation**: Identify target git diff or file path.
2. **Execute Review**: Run multi-model review across ready providers:

```bash
!{QBIN="$HOME/.gemini/extensions/quintet/bin/quintet"; [ -x "$QBIN" ] || QBIN=quintet; "$QBIN" review {{args}}}
```

3. **Fallback & Error Handling**:
   - If a provider fails or times out during diff review, continue with findings from remaining ready providers and note the skipped model.
   - If diff is too large, suggest narrowing diff scope (e.g. `git diff HEAD~1 -- path/to/file`).

4. **Synthesis & Handoff**:
   - **Blocking Issues**: Highlight critical bugs, security vulnerabilities, or breaking changes agreed upon by 2+ models.
   - **Suggestions**: List minor code quality, performance, or style improvements.
   - **Verdict**: Provide a clear **Go / No-Go / Change Requested** recommendation with explicit reasoning.
