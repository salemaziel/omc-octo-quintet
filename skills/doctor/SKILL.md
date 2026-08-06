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

2. **Binary Resolution Guard**:
   - If the binary is missing or not executable, instruct the user to verify Quintet extension installation or check path `$HOME/.gemini/extensions/quintet/bin/quintet`.

3. **Pool Diagnostics & Explicit Remediation Fixes**:
   - List all ready providers (`ready: true`, `auth: ok`).
   - For unauthenticated providers (`auth=none`), report the specific one-time fix command:
     - **Claude Code**: `claude login`
     - **Codex CLI**: `codex login`
     - **Gemini CLI**: `gemini login` or `gcloud auth application-default login`
     - **GitHub Copilot**: `gh auth login` or `copilot auth`
     - **Qwen Code**: `qwen` (run interactively once to complete OAuth)

4. **Re-verification Feedback Loop**:
   - Re-run `"$QBIN" doctor` after authenticating any unready CLI provider to verify the state updated to `ready: true`.

5. **Output Reporting**: Summarize active provider pool capacity (e.g. `4/5 providers ready`) and exclude unready models from subsequent orchestration tasks.

## Reference Materials

- Complete CLI subcommands, options, and setup: [references/CLI_REFERENCE.md](../../references/CLI_REFERENCE.md)
