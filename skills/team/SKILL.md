---
name: team
description: Spawns persistent tmux worker teams across coding-agent CLIs (Claude, Codex, Gemini, Copilot, Qwen) to implement features, refactor code, and edit files in parallel. Use when executing multi-file implementation plans, running parallel AI workers, or building complex features concurrently.
metadata:
  version: 0.1.0
  category: multi-agent-orchestration
  tags: quintet, team, tmux, parallel-workers, file-editing
---

# Quintet Team Worker Runtime

Launches persistent tmux worker panes to execute parallel file-editing tasks across multiple AI coding-agent CLIs.

## Workflow

1. **Pool Verification**: Run doctor to confirm active provider pool:

```bash
!{QBIN="$HOME/.gemini/extensions/quintet/bin/quintet"; [ -x "$QBIN" ] || QBIN=quintet; "$QBIN" doctor}
```

2. **Launch Worker Team**: Initialize persistent tmux worker panes with assigned subtasks:

```bash
!{QBIN="$HOME/.gemini/extensions/quintet/bin/quintet"; [ -x "$QBIN" ] || QBIN=quintet; "$QBIN" team 2:codex,1:gemini "build export feature" --name export --tasks "implement serializer in src/export/||add tests in tests/export/"}
```

3. **Task Monitoring & Status Polling**:
   - Inspect active team status and taskboard:
     ```bash
     !{QBIN="$HOME/.gemini/extensions/quintet/bin/quintet"; [ -x "$QBIN" ] || QBIN=quintet; "$QBIN" status --name export}
     ```
   - Monitor worker taskboard progress across tmux worker panes until all assigned subtasks emit `DONE`.

4. **Verification & Error Handling**:
   - *Validation*: Run build/test verification commands (e.g., `npm test`, `cargo test`, `pytest`) to confirm edits compile and pass tests cleanly.
   - *Feedback Loop*: If a worker fails or emits errors, inspect worker log pane (`tmux attach -t quintet-export`), resolve failure, or re-assign subtask.

5. **Shutdown & Handoff**:
   - Gracefully shut down worker session:
     ```bash
     !{QBIN="$HOME/.gemini/extensions/quintet/bin/quintet"; [ -x "$QBIN" ] || QBIN=quintet; "$QBIN" stop export}
     ```
   - Deliver handoff summary detailing modified files, commit hashes, and verification test results.
