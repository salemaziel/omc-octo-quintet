---
description: Run an Interpretable Context Methodology (ICM) staged folder pipeline with human check gates.
argument-hint: init <name> [--template debate-build|review-fix] [--goal GOAL] | status <name> | advance <name> [--auto]
allowed-tools: Bash, Read, Glob, Grep
---

Manage or execute an ICM staged folder pipeline for: **$ARGUMENTS**

Follow the `quintet-pipeline` workflow:

1. Resolve the quintet binary:
   ```bash
   BIN="${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/bin/quintet}"
   [ -n "$BIN" ] && [ -x "$BIN" ] || BIN="$(command -v quintet 2>/dev/null || echo quintet)"
   ```

2. Pipeline commands:
   - **Initialize**: `$BIN pipeline init <name> --template debate-build --goal "<goal>"`
   - **Check Status**: `$BIN pipeline status <name>`
   - **Advance Stage**: `$BIN pipeline advance <name>` (pauses at Human Check gate)
   - **Walk Test**: `$BIN walk <name>` (audits L2 contracts and filesystem state)

3. Principles enforced:
   - **Numbered Stages**: `01_debate`, `02_spec`, `03_implement`, `04_review`
   - **Every Output is an Edit Surface**: Inspect intermediate files in `output/` and edit in place before advancing.
   - **Filesystem as State Machine**: Status is derived by artifact presence in `output/`.
