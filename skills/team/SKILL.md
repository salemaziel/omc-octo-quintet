---
name: team
description: Quick-action skill to spawn persistent tmux worker teams across coding-agent CLIs (Claude, Codex, Antigravity, Copilot, Qwen, OpenCode) to implement features and edit files in parallel. Use for team execution via /team. For full lifecycle management, steering, and recovery, see quintet-team-runtime.
metadata:
  version: 0.3.0
  category: multi-agent-orchestration
  tags: quintet, team, tmux, parallel-workers, file-editing
---

# Quintet Team Worker Runtime

Launches persistent tmux worker panes to execute parallel file-editing tasks across multiple AI coding-agent CLIs.

## Workflow

1. **Pool Verification**: Run doctor to confirm active provider pool:

```bash
QBIN="${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/bin/quintet}"
[ -n "$QBIN" ] && [ -x "$QBIN" ] || QBIN="$HOME/.gemini/config/plugins/quintet/bin/quintet"
[ -x "$QBIN" ] || QBIN="$HOME/.gemini/extensions/quintet/bin/quintet"
[ -x "$QBIN" ] || QBIN="$(command -v quintet 2>/dev/null || echo quintet)"
"$QBIN" doctor
```

2. **Launch Worker Team**: Initialize persistent tmux worker panes with assigned subtasks:

```bash
QBIN="${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/bin/quintet}"
[ -n "$QBIN" ] && [ -x "$QBIN" ] || QBIN="$HOME/.gemini/config/plugins/quintet/bin/quintet"
[ -x "$QBIN" ] || QBIN="$HOME/.gemini/extensions/quintet/bin/quintet"
[ -x "$QBIN" ] || QBIN="$(command -v quintet 2>/dev/null || echo quintet)"
"$QBIN" team 2:codex,1:opencode "build export feature" --name export --tasks "implement serializer in src/export/||add tests in tests/export/"
```

3. **Task Monitoring & Status Polling**:
   - Inspect active team status and taskboard:
     ```bash
     "$QBIN" team status export
     ```
   - Monitor worker taskboard progress across tmux worker panes until all assigned subtasks emit `DONE`.

4. **Verification & Error Handling**:
   - *Validation*: Run build/test verification commands (e.g., `npm test`, `cargo test`, `pytest`) to confirm edits compile and pass tests cleanly.
   - *Feedback Loop*: If a worker fails or emits errors, inspect worker log pane (`"$QBIN" team capture export`), resolve failure, or re-assign subtask.

5. **Shutdown & Structured Handoff**:
   - Gracefully shut down worker session:
     ```bash
     "$QBIN" team shutdown export --graceful
     ```
   - Format deliverable summary:
     ```text
     ## Team Execution Summary
     - **Team Name**: export
     - **Workers**: 2:codex, 1:opencode
     - **Files Modified**: src/export/serializer.rs, tests/export/test_serializer.rs
     - **Verification**: All 12 unit tests passing (0 failures)
     ```

## Reference Materials

- Complete CLI subcommands, flags, and provider pool options: [references/CLI_REFERENCE.md](../../references/CLI_REFERENCE.md)
