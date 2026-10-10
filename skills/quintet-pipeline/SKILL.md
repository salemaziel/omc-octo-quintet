---
name: quintet-pipeline
description: Orchestrate multi-stage AI workflows using Interpretable Context Methodology (ICM) staged folder pipelines with human check gates and edit surfaces. Use when executing complex compound workflows (e.g. debate -> spec -> worktree implementation -> review -> verify) or two-phase review-and-fix tasks where humans must review intermediate outputs.
metadata:
  version: 0.4.0
  category: multi-agent-orchestration
  tags: quintet, icm, pipeline, staged-folders, human-in-the-loop, walk-test
---

# Quintet ICM Staged Folder Pipelines

Orchestrates multi-stage workflows across Quintet CLI agents following the **Interpretable Context Methodology (ICM)** (Van Clief & McDermott, arXiv:2603.16021). Numbered folders carry sequencing, L2 `CONTEXT.md` contracts carry context scoping, intermediate files in `output/` carry state, and every boundary serves as an editable human check surface.

## Core Invariants Enforced

1. **One Folder, One Stage**: Each stage does one job (`01_debate`, `02_spec`, `03_implement`, `04_review`).
2. **Layered Context Contracts**: Every working stage and worker has an explicit `CONTEXT.md` defining Inputs, Process, Outputs, and Human Check.
3. **Every Output is an Edit Surface**: Intermediate files in `output/` are plain markdown/JSON that humans can edit before downstream stages run.
4. **Filesystem as State Machine**: Status is derived by scanning artifacts on disk rather than relying on unstructured logs.
5. **Token Discipline**: Stage and worker contracts stay strictly within the 2,000–8,000 token budget.

## Workflow

### 1. Initialize Pipeline

Choose a template (`debate-build` or `review-fix`) and initialize:

```bash
QBIN="${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/bin/quintet}"
[ -n "$QBIN" ] && [ -x "$QBIN" ] || QBIN="$HOME/.gemini/config/plugins/quintet/bin/quintet"
[ -x "$QBIN" ] || QBIN="$HOME/.gemini/extensions/quintet/bin/quintet"
[ -x "$QBIN" ] || QBIN="$(command -v quintet 2>/dev/null || echo quintet)"

"$QBIN" pipeline init my-feature --template debate-build --goal "Design and implement user rate limiting"
```

### 2. Inspect Pipeline Status

Check current stage and completed artifacts:

```bash
"$QBIN" pipeline status my-feature
```

### 3. Advance with Human Check Gates

Run the active stage:

```bash
"$QBIN" pipeline advance my-feature
```

The pipeline pauses at human check gates so the user can inspect or edit `output/consensus.md` or `output/findings.json` in place before downstream stages run. Use `--auto` to advance automatically once verified.

### 4. Audit with the Cold-Agent Walk Test

Validate contract integrity and state derivability:

```bash
"$QBIN" walk my-feature
```

A passing Walk Test proves that any newly spawned agent or human can understand the run's goals, inputs, boundaries, and outputs without reading raw terminal logs.
