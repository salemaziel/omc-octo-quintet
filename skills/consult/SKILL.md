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
!{QBIN="$HOME/.gemini/extensions/quintet/bin/quintet"; [ -x "$QBIN" ] || QBIN=quintet; "$QBIN" consult "Best approach to dedupe a 10M-row stream in Rust?" claude,codex,gemini}
```

3. **Output Validation & Fallback**:
   - *Validation*: Verify responses were collected from ready models.
   - *Fallback*: If a provider times out or errors, log the failure and synthesize from available responses.
   - *Empty Pool Guard*: If zero providers respond, prompt user to check CLI auth.

4. **Structured Synthesis & Deliverable Format**:
   Format the deliverable strictly using the following structure:

```text
Consensus (3/3): High-confidence agreement across models.
Disagreements: Surface points where models differ and note which model held which view.
Recommendation: One clear recommendation with technical reasoning.
```

## Reference Materials

- Complete CLI subcommands, options, and setup: [references/CLI_REFERENCE.md](../../references/CLI_REFERENCE.md)
