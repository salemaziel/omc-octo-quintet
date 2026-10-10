---
name: doctor
description: Quick-action diagnostic skill to audit installed CLI binaries and authentication states across Quintet providers (Claude, Codex, Antigravity, Copilot, Qwen, OpenCode). Use when verifying provider pools or diagnosing CLI readiness via /doctor.
metadata:
  version: 0.2.0
  category: multi-agent-orchestration
  tags: quintet, doctor, readiness, auth, diagnostics
---

# Quintet Doctor

Audits installed CLI binaries and authentication states across all Quintet provider models to establish the active worker pool.

## Workflow

1. **Execute Readiness Check**:

```bash
QBIN="${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/bin/quintet}"
[ -n "$QBIN" ] && [ -x "$QBIN" ] || QBIN="$HOME/.gemini/config/plugins/quintet/bin/quintet"
[ -x "$QBIN" ] || QBIN="$HOME/.gemini/extensions/quintet/bin/quintet"
[ -x "$QBIN" ] || QBIN="$(command -v quintet 2>/dev/null || echo quintet)"
"$QBIN" doctor
```

2. **Binary Resolution Guard**:
   - If the binary is missing or not executable, verify the Quintet plugin installation path (`$HOME/.gemini/config/plugins/quintet/bin/quintet`) or extension path (`$HOME/.gemini/extensions/quintet/bin/quintet`).

3. **Pool Diagnostics & Explicit Remediation Fixes**:
   - List all ready providers (`ready: true`, `auth: ok`).
   - For unauthenticated providers (`auth=none`), report the specific one-time fix command:
     - **Claude Code**: `claude login`
     - **Codex CLI**: `codex login`
     - **Google Antigravity CLI (agy)**: Run `agy` interactively once to complete authentication, or set `GOOGLE_API_KEY` (Gemini CLI alias: `gemini`)
     - **GitHub Copilot**: `gh auth login` or `copilot auth`
     - **Qwen Code**: `qwen` (run interactively once to complete OAuth)
     - **OpenCode CLI**: `opencode auth login` or run `opencode` interactively once (install: `npm install -g opencode-ai`)

4. **Re-verification Feedback Loop**:
   - Re-run `"$QBIN" doctor` after authenticating any unready CLI provider to verify the state updated to `ready: true`.

5. **Output Reporting**: Summarize active provider pool capacity (e.g. `5/6 providers ready`) and exclude unready models from subsequent orchestration tasks.

## Reference Materials

- Complete CLI subcommands, options, and setup: [references/CLI_REFERENCE.md](../../references/CLI_REFERENCE.md)
