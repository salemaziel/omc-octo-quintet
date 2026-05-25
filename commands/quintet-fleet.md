---
description: Fan a prompt out to several coding-agent CLIs in parallel (alias of consult) and synthesize.
argument-hint: "<prompt>" [providers]
allowed-tools: Bash
---

Dispatch to the quintet fleet: **$ARGUMENTS**

```bash
${CLAUDE_PLUGIN_ROOT}/bin/quintet fleet "<prompt>" [providers]
```

Then synthesize the collected answers (consensus + disagreements + one recommendation) rather than pasting raw blocks. See the `quintet-fleet-dispatch` skill. For an argue-and-converge flow use `/quintet:debate`; for code review use `/quintet:review`.
