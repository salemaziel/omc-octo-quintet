---
description: Get a multi-model code review of a diff, file, or change description across the AI CLIs.
argument-hint: "<diff|file-path|description>" [providers]
allowed-tools: Bash, Read
---

Run a multi-model quintet review of: **$ARGUMENTS**

1. Resolve the target. If `$ARGUMENTS` is a path, read it or use the diff; if the user means the current changes, capture `git diff` first.
2. Run:
   ```bash
   ${CLAUDE_PLUGIN_ROOT}/bin/quintet review "<diff-or-target>" [providers]
   ```
3. **Aggregate the findings**: merge duplicate findings, rank by severity, and resolve disagreements between reviewers. Present one consolidated, deduplicated review with file:line references where given — not separate per-model dumps.

Follow the `quintet-fleet-dispatch` skill.
