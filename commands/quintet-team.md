---
description: Launch a persistent multi-agent CLI worker team in tmux across claude/codex/gemini/copilot/qwen.
argument-hint: <spec> "<task>"   e.g. 2:codex,1:gemini "build the export feature"
allowed-tools: Bash, Read, Glob, Grep
---

Launch a quintet worker team for: **$ARGUMENTS**

Follow the `quintet-team-runtime` skill. Steps:

1. Run `${CLAUDE_PLUGIN_ROOT}/bin/quintet doctor` and confirm the requested providers are ready.
2. Read the repo enough to split the task into **non-overlapping, file/module-scoped subtasks** — two workers must never own the same files.
3. Launch with distinct per-worker subtasks:
   ```bash
   ${CLAUDE_PLUGIN_ROOT}/bin/quintet team <spec> "<shared goal>" --name <slug> --cwd <repo> --tasks "s1||s2||..."
   ```
4. Monitor with `quintet team status <name>` and `quintet team capture <name>` (poll — don't assume success). Read `.quintet/teams/<name>/taskboard.md`. Steer drifting workers with `quintet team send`.
5. **Verify the actual files/tests yourself**, then `quintet team shutdown <name>`.

If `$ARGUMENTS` doesn't already contain a spec (like `2:codex,1:gemini`), propose one based on the task and the ready providers before launching.
