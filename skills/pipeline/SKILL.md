---
name: pipeline
description: Run an Interpretable Context Methodology (ICM) staged folder pipeline with human check gates and edit surfaces. Use for multi-stage debate-build or review-fix workflows.
metadata:
  version: 0.4.0
  category: multi-agent-orchestration
  tags: quintet, icm, pipeline, staged-folders
---

# Quintet Pipeline

Execute an ICM staged folder pipeline across Quintet CLI agents.

```bash
QBIN="${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/bin/quintet}"
[ -n "$QBIN" ] && [ -x "$QBIN" ] || QBIN="$HOME/.gemini/config/plugins/quintet/bin/quintet"
[ -x "$QBIN" ] || QBIN="$HOME/.gemini/extensions/quintet/bin/quintet"
[ -x "$QBIN" ] || QBIN="$(command -v quintet 2>/dev/null || echo quintet)"

# 1. Initialize
"$QBIN" pipeline init my-task --template debate-build --goal "Task description"

# 2. Check Status
"$QBIN" pipeline status my-task

# 3. Advance Active Stage (pauses at human check gate)
"$QBIN" pipeline advance my-task

# 4. Audit
"$QBIN" walk my-task
```
