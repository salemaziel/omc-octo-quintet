---
name: review
description: Runs a multi-model code review of a diff or target file across ready AI provider CLIs (Claude, Codex, Gemini, Copilot, Qwen), synthesizing severity-ranked findings into a single go/no-go verdict. Use when reviewing code changes, auditing git diffs, checking PRs, inspecting security flaws, or getting multi-AI code reviews.
metadata:
  version: 0.1.0
  category: multi-agent-orchestration
  tags: quintet, review, code-review, git-diff, pr-review, security-audit
---

# Quintet Multi-Model Code Review

Performs multi-perspective code reviews across ready AI provider CLIs for git diffs or file contents, consolidating findings into an actionable verdict.

## Workflow

1. **Target Preparation**: Identify target git diff or file path.
2. **Execute Review**: Run multi-model review across ready providers:

```bash
!{QBIN="$HOME/.gemini/extensions/quintet/bin/quintet"; [ -x "$QBIN" ] || QBIN=quintet; "$QBIN" review "$(git diff HEAD~1)" claude,gemini,copilot}
```

3. **Output Validation & Fallback**:
   - *Validation*: Confirm that review output was received from at least 1 ready provider.
   - *Fallback*: If a provider fails or times out, proceed with remaining findings and note the skipped model in the synthesis header.
   - *Diff Size*: If diff exceeds context limits, narrow scope: `"$QBIN" review "$(git diff HEAD~1 -- path/to/file)"`.

4. **Structured Synthesis & Deliverable Format**:
   Format the deliverable strictly using the following structure:

```text
## Verdict: [Go / No-Go / Changes Requested]

### Blocking Issues (2/3 models agree)
- **[Severity: High]** Description of critical bug, security flaw, or breaking change.

### Worth Fixing
- **[Severity: Medium]** Refactoring recommendation or performance optimization.

### Recommendation
- Summary recommendation with explicit technical reasoning.
```

## Reference Materials

- Complete CLI subcommands, options, and setup: [references/CLI_REFERENCE.md](../../references/CLI_REFERENCE.md)
