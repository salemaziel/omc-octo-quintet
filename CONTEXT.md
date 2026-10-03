# Quintet (`omc-octo-quintet`)

> **Multi-Agent Coding CLI Orchestrator** — Persistent tmux worker teams and one-shot fleet dispatches across Claude Code, Codex, Antigravity (agy), Copilot, Qwen, and OpenCode.

Quintet is the unified multi-agent orchestrator plugin and CLI for AI coding agents. It merges the persistent coordinating worker teams model of `omc-teams` with the one-shot multi-model consensus, debate, and review model of `claude-octopus`, supporting six major agent CLIs.

---

## 🏗 Architecture & Components

- **`bin/quintet`**: Unified shell CLI entry point for team management and fleet dispatches.
- **`lib/providers.sh`**: Provider abstraction registry (`claude`, `codex`, `agy`, `copilot`, `qwen`, `opencode`). Defines binary resolution, authentication detection, one-shot invocation, tmux worker commands, and warmup delays.
- **`lib/team.sh`**: Persistent tmux worker runtime. Decomposes tasks across workers with dedicated tmux panes and a markdown taskboard (`taskboard.md`).
- **`lib/fleet.sh`**: Headless one-shot parallel fleet execution with consensus synthesis, debate rounds, and diff reviews.
- **`lib/reliability.sh`**: Circuit breaker and automatic fallback routing.
- **`lib/tmux.sh`**: Low-level tmux window/pane management and key injection.
- **`skills/`**: Agent skills for orchestration, team runtime, fleet dispatch, reviews, consults, debates, and doctor readiness.
- **`commands/`**: Slash commands and TOML templates for Claude, Codex, Gemini/AGY, and Copilot.
- **`tests/smoke.sh`**: Test suite verifying syntax, CLI surface, provider registry, and team lifecycle.

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
