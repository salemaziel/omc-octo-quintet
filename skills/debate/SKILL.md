---
name: debate
description: Quick-action skill to run a two-round cross-model debate across ready AI provider CLIs (Claude, Codex, Antigravity, Copilot, Qwen, OpenCode) and synthesize a converged verdict. Use when resolving contested decisions via /debate.
metadata:
  version: 0.3.0
  category: multi-agent-orchestration
  tags: quintet, debate, cross-critique, multi-model, architecture
---

# Quintet Debate

Executes a two-round cross-critique debate across ready AI provider CLIs to surface hidden trade-offs and drive convergence on contested decisions.

## Workflow

1. **Check Readiness**: Verify active providers with `quintet doctor`.
2. **Execute Debate**: Trigger the two-round cross-model debate:

```bash
QBIN="${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/bin/quintet}"
[ -n "$QBIN" ] && [ -x "$QBIN" ] || QBIN="$HOME/.gemini/config/plugins/quintet/bin/quintet"
[ -x "$QBIN" ] || QBIN="$HOME/.gemini/extensions/quintet/bin/quintet"
[ -x "$QBIN" ] || QBIN="$(command -v quintet 2>/dev/null || echo quintet)"
"$QBIN" debate "Should we use gRPC or REST for this internal service?" claude,codex,agy,opencode
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
