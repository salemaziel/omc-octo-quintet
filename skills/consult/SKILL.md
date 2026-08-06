---
name: consult
description: Fans out a question across all ready AI provider CLIs in parallel and synthesizes a single recommendation. Use when comparing AI answers, asking multiple models (Claude, Codex, Gemini, Copilot, Qwen), seeking multi-model consensus, or aggregating opinions on read-only questions.
metadata:
  version: 0.1.0
  category: multi-agent-orchestration
  tags: quintet, consult, multi-model, consensus, parallel-ai
---

# Quintet Consult

Fans out a question across ready AI provider CLIs in parallel and synthesizes a single consensus recommendation.

## Workflow

1. **Check Readiness**: Verify provider availability using `quintet doctor` if pool status is unknown.
2. **Execute Consult**: Fan out the question across ready providers:

```bash
!{QBIN="$HOME/.gemini/extensions/quintet/bin/quintet"; [ -x "$QBIN" ] || QBIN=quintet; "$QBIN" consult {{args}}}
```

3. **Fallback & Error Handling**:
   - If a provider times out or returns an error, note the provider failure in the synthesis log and proceed with the available responses.
   - If zero providers return valid responses, inform the user and request CLI authentication check.

4. **Synthesis & Handoff**:
   - State the **Consensus** (where models agree).
   - Highlight **Disagreements** (noting which model held which position).
   - Deliver **One Recommendation** with clear technical reasoning.
   - *Constraint*: Do not output raw pasted response blocks; the synthesized verdict is the primary deliverable.
