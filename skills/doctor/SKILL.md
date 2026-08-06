---
name: doctor
description: Audits and checks which Quintet provider CLIs (Claude, Codex, Gemini, Copilot, Qwen) are installed, authenticated, and ready for fleet/team orchestration. Use when checking AI model readiness, diagnosing CLI authentication, or verifying available provider pools.
metadata:
  version: 0.1.0
  category: multi-agent-orchestration
  tags: quintet, doctor, readiness, auth, diagnostics
---

# Quintet Doctor

Audits installed CLI binaries and authentication states across all Quintet provider models to establish the active worker pool.

## Workflow

1. **Execute Readiness Check**:

```bash
!{QBIN="$HOME/.gemini/extensions/quintet/bin/quintet"; [ -x "$QBIN" ] || QBIN=quintet; "$QBIN" doctor}
```

2. **Pool Diagnostics & Action Rules**:
   - List all ready providers (`ready: true`, `auth: ok`).
   - For any provider displaying `auth=none` or unauthenticated state, report the one-time interactive login command (e.g. `qwen`, `codex login`, `claude login`).
   - If zero providers are ready, stop execution and guide the user through authenticating at least one CLI provider before running fleet or team commands.

3. **Output Reporting**: Summarize active provider pool capacity (e.g. `4/5 providers ready`) and exclude unready models from subsequent orchestration tasks.
