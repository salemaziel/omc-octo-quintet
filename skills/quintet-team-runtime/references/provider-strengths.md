# Provider strengths

Canonical mapping of quintet providers to the work they're best suited for. This is the **single source of truth** — `quintet-orchestration` and the `quintet-conductor` agent link here rather than restating it.

| Provider | Use for |
| --- | --- |
| `claude` | General implementation, refactors, careful multi-file edits, reasoning-heavy work. |
| `codex` | Deep code implementation, framework-specific generation, debugging. |
| `gemini` | Breadth: research-adjacent tasks, large-context synthesis, alternative approaches. |
| `copilot` | An extra independent perspective (uses a GitHub Copilot subscription; 1 premium request per prompt). |
| `qwen` | Free-tier bulk work (OAuth ~1–2k req/day) — good for volume tasks where cost matters. |

Quick rule of thumb when decomposing a team: **Codex/Claude → implementation, Gemini → breadth/research, Copilot → extra perspective, Qwen → free-tier bulk**.
