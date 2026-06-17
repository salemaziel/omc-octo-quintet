---
description: Run a two-round cross-model debate (independent answers, then mutual critique) across the AI CLIs.
argument-hint: "<question>" [providers]   e.g. "gRPC or REST for this service?" claude,codex,gemini
allowed-tools: Bash
---

Run a quintet debate on: **$ARGUMENTS**

```bash
${CLAUDE_PLUGIN_ROOT}/bin/quintet debate "<question>" [providers]
```

This runs round 1 (independent positions) then round 2 (each model critiques the others and refines). Per-provider completion is streamed live, and the full transcript is saved to `${QUINTET_HOME:-~/.quintet}/debates/<ts>/transcript.md` (the command prints the path).

After it returns:
1. **Show the debate, not just the result.** Give the user each model's key argument in a line or two (round-1 stance → how round 2 shifted it), and link the printed transcript path so they can read the raw arguments.
2. **Then synthesize from the round-2 positions**: state the consensus, list any points that stayed contested and why, and give one recommendation.
3. **Report failures honestly** — a provider shown as `✗ … failed` did not contribute.

Follow the `quintet-fleet-dispatch` skill.
