---
description: Fan a single prompt out to several coding-agent CLIs in parallel and synthesize their answers.
argument-hint: "<question>" [providers]   e.g. "best way to dedupe a stream?" claude,codex,gemini
allowed-tools: Bash
---

Consult the quintet fleet about: **$ARGUMENTS**

1. Optionally check `${CLAUDE_PLUGIN_ROOT}/bin/quintet doctor` if unsure which providers are ready.
2. Run:
   ```bash
   ${CLAUDE_PLUGIN_ROOT}/bin/quintet consult "<question>" [providers]
   ```
   (providers default to `all`; pass a comma list to narrow.)
3. **Synthesize** — do not paste raw blocks. Report where the models agree (high confidence), where they disagree (and which held which view), and give one recommendation with reasoning.

Follow the `quintet-fleet-dispatch` skill.
