# Quintet (`omc-octo-quintet`)

> **Multi-Agent Coding CLI Orchestrator** — Persistent tmux worker teams and one-shot fleet dispatches across Claude Code, Codex, Antigravity (agy), Copilot, Qwen, and OpenCode.

Quintet is the unified multi-agent orchestrator plugin and CLI for AI coding agents. It merges the persistent coordinating worker teams model of `omc-teams` with the one-shot multi-model consensus, debate, and review model of `claude-octopus`, supporting six major agent CLIs.

---

## 🏗 Architecture & Components

- **`bin/quintet`**: Unified shell CLI entry point for team management, fleet dispatches, diagnostics, and pruning.
- **`lib/providers.sh`**: Provider abstraction registry (`claude`, `codex`, `agy`, `copilot`, `qwen`, `opencode`). Defines binary resolution, authentication detection, one-shot invocation, tmux worker commands, model selection, reasoning effort, safety mode, and warmup delays.
- **`lib/roles.sh`**: Subagent worker role registry and prompt injection loader.
- **`lib/team.sh`**: Persistent tmux worker runtime supporting `N:provider:role:model` specs, taskboard coordination, and watchdog modal diagnostics (`quintet team doctor`).
- **`lib/worktrees.sh`**: Headless git worktree runtime (`quintet worktrees`) for parallel branch isolation and automated merges.
- **`lib/fleet.sh`**: One-shot parallel fleet execution (tmux-by-default with fallback) with consensus synthesis, debate rounds, and diff reviews.
- **`lib/handoff.sh`**: Two-phase review-to-team handoff pipeline automation (`quintet handoff review`).
- **`lib/prune.sh`**: State retention & garbage collection (`quintet prune`) for stale teams and debate archives.
- **`lib/reliability.sh`**: Circuit breaker and automatic fallback routing.
- **`lib/tmux.sh`**: Low-level tmux window/pane management and key injection.
- **`roles/`**: Subagent role definitions (`implementer`, `code-reviewer`, `security-auditor`, `test-engineer`, `debugger`, `devops-troubleshooter`).
- **`skills/`**: Agent skills for orchestration, team runtime, fleet dispatch, reviews, consults, debates, and doctor readiness.
- **`commands/`**: Slash commands and TOML templates for Claude, Codex, Gemini/AGY, and Copilot.
- **`tests/smoke.sh`**: Heavyweight manual tmux integration test harness. **Do NOT run automatically** — only run if the user explicitly requests running smoke tests.

---

## 🚀 Providers Supported

| Provider | Indicator | Binary | Strengths & Workload |
|---|---|---|---|
| `claude` | 🟣 | `claude` | Deep architecture, complex implementation, refactoring |
| `codex` | 🔴 | `codex` | Implementation, tests, fast iterative edits |
| `agy` | 🟡 | `agy` | Large context synthesis, research-adjacent, alternative designs |
| `copilot` | 🟢 | `copilot` | Independent second perspective |
| `qwen` | 🔵 | `qwen` | High-volume free OAuth bulk tasks |
| `opencode` | 🟧 | `opencode` | Multi-model routing, open-source models, independent checks |

## Operational Notes

- `--safe` team workers block on approval prompts; answer them with `quintet team send <name> <worker> "<text>"`. No escalation path exists yet (it is a feature, not implemented).
- Worker targeting is exact-name only (`w1-claude`); the `w1` shorthand is gone.
- `--no-mcp` is partial for copilot (built-in servers only); agy/qwen/opencode have no MCP-off flag. `team.json` records `no_mcp_effective`.
- Team windows stay open as dead panes after the CLI exits (`remain-on-exit`) until `team shutdown`.
- `quintet team doctor` reports status 2 ("inspection error") when a pane can't be captured, and compares windows with `team.json` (missing/extra).
- Auth detection is a heuristic; `unknown` is shown as `unverified`.
