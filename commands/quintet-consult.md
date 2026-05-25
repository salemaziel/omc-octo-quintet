---
description: Fan a single prompt out to several coding-agent CLIs in parallel and synthesize their answers.
argument-hint: "<question>" [providers]   e.g. "best way to dedupe a stream?" claude,codex,gemini
allowed-tools: Bash
---

Consult the quintet fleet about: **$ARGUMENTS**

1. Check `${CLAUDE_PLUGIN_ROOT}/bin/quintet doctor` first and build your pool from the providers marked ready.
   - Never claim a provider ran if it shows missing or `auth=none`.
   - If zero providers are ready, stop and tell the user which CLIs need installing/authenticating.
2. Run:
   ```bash
   ${CLAUDE_PLUGIN_ROOT}/bin/quintet consult "$ARGUMENTS"
   ```
   If the user explicitly supplied a provider list, preserve it as part of `$ARGUMENTS`.
3. **Synthesize** — do not paste raw blocks. Report where the models agree (high confidence), where they disagree (and which held which view), and give one recommendation with reasoning.

Follow the `quintet-fleet-dispatch` skill.
