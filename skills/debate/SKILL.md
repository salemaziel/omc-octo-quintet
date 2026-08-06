---
name: debate
description: Runs a two-round cross-model debate across ready AI provider CLIs, then synthesizes a converged verdict. Use when resolving contested technical decisions, evaluating architectural trade-offs, or requiring multi-model cross-critique between AI CLIs.
metadata:
  version: 0.1.0
  category: multi-agent-orchestration
  tags: quintet, debate, cross-critique, multi-model, architecture
---

# Quintet Debate

Executes a two-round cross-critique debate across ready AI provider CLIs to surface hidden trade-offs and drive convergence on contested decisions.

## Workflow

1. **Check Readiness**: Verify active providers with `quintet doctor`.
2. **Execute Debate**: Trigger the two-round cross-model debate:

```bash
!{QBIN="$HOME/.gemini/extensions/quintet/bin/quintet"; [ -x "$QBIN" ] || QBIN=quintet; "$QBIN" debate "Should we use gRPC or REST for this internal service?" claude,codex,gemini}
```

3. **Output Validation & Fallback**:
   - *Validation*: Confirm Round-2 refined positions were generated.
   - *Fallback*: If a provider fails during Round 1 or Round 2, route around it using fallback responses from remaining ready models.

4. **Structured Synthesis & Deliverable Format**:
   Format the deliverable strictly using the following structure:

```text
Round-2 Consensus: Where models converged after cross-critique.
Contested Points: Key trade-offs that stayed disputed and why.
Recommendation: One actionable decision with trade-off analysis.
```

## Reference Materials

- Complete CLI subcommands, options, and setup: [references/CLI_REFERENCE.md](../../references/CLI_REFERENCE.md)
