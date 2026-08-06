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
!{QBIN="$HOME/.gemini/extensions/quintet/bin/quintet"; [ -x "$QBIN" ] || QBIN=quintet; "$QBIN" debate {{args}}}
```

3. **Fallback & Error Handling**:
   - If a provider fails during Round 1 or Round 2, route around it using fallback responses from remaining ready models.
   - If only one model completes both rounds, fall back to single-model reasoning and inform the user.

4. **Synthesis & Handoff**:
   - Base synthesis on **Round-2 refined positions**.
   - Detail where models **converged** after cross-critique.
   - Highlight points that **remained contested** and explain why.
   - Deliver **One Final Recommendation** with actionable trade-off analysis.
