---
description: Check readiness of all quintet providers (claude/codex/gemini/copilot/qwen), tmux, and jq.
allowed-tools: Bash
---

Run the quintet environment check and report the results clearly.

```bash
${CLAUDE_PLUGIN_ROOT}/bin/quintet doctor
```

Summarize which providers are ready, which are missing or unauthenticated, and give the exact install/auth hint for any that aren't. Note that `qwen` typically shows `auth=none` until the user runs `qwen` once to complete OAuth.
