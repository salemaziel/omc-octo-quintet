---
description: Run a two-round cross-model debate (independent answers, then mutual critique) across the AI CLIs.
argument-hint: "<question>" [providers]   e.g. "gRPC or REST for this service?" claude,codex,gemini
allowed-tools: Bash
---

Run a quintet debate on: **$ARGUMENTS**

```bash
${CLAUDE_PLUGIN_ROOT}/bin/quintet debate "<question>" [providers]
```

This runs round 1 (independent positions) then round 2 (each model critiques the others and refines). After it returns, **synthesize from the round-2 positions**: state the consensus, list any points that stayed contested and why, and give one recommendation. Follow the `quintet-fleet-dispatch` skill.
