# Quintet (Gemini CLI extension)

Quintet drives five coding-agent CLIs — `claude`, `codex`, `gemini`, `copilot`, `qwen` — through one entry point, the `quintet` binary. It bundles two execution models:

- **Team mode** (persistent): long-lived worker processes in tmux that autonomously edit files in parallel. Use for *doing work*.
- **Fleet mode** (one-shot): a single prompt fanned out to several CLIs headless, with a circuit-breaker + fallback reliability layer. Use for *getting perspectives* (`consult` / `debate` / `review`).

## Locating the bundled CLI

The CLI ships *inside* this extension — nothing needs to go on your PATH. Gemini installs the extension to `~/.gemini/extensions/quintet/`, so the binary is at `~/.gemini/extensions/quintet/bin/quintet`. Resolve it once per shell and reuse it:

```bash
QBIN="$HOME/.gemini/extensions/quintet/bin/quintet"; [ -x "$QBIN" ] || QBIN=quintet
"$QBIN" doctor
```

(The `|| QBIN=quintet` only matters if you've separately put it on PATH; the bundled path is the default.) The examples below write `quintet` for brevity — invoke `$QBIN` instead. Team mode also needs `tmux`.

## Always check readiness first

Before routing anything, run `quintet doctor` and build your pool from the providers marked ready. Never claim a provider ran if it shows `auth=none` or missing — name the one-time fix to the user instead. If zero providers are ready, stop and say which CLIs need installing/authenticating; do not report an empty result as success.

## Choosing a mode

The single question that resolves almost every routing decision: **does the request produce file edits, or opinions?**

- Edits / parallel build / refactor → **team mode**: `quintet team <spec> "<goal>" --name <slug> --cwd <repo> --tasks "s1||s2||..."`
- A decision, second opinion, or review → **fleet mode**: `quintet consult "<q>"`, `quintet debate "<q>"`, `quintet review "<diff>"`

When ambiguous ("improve this module with the models"), ask whether they want the models to *write the change* (team) or *propose it* (fleet) before launching.

## Team mode discipline

Workers share one working directory and can clobber each other. Decompose the task into file/module-scoped subtasks so no two workers own the same paths, then map each to a provider (Codex/Claude → implementation, Gemini → breadth/docs, Copilot → extra perspective, Qwen → free-tier bulk). Monitor with `quintet team status` / `quintet team capture` and read `.quintet/teams/<name>/taskboard.md` — but **verify the real files and tests**, not the self-reported taskboard. Always `quintet team shutdown <name>` when verified. Max 10 workers; 3–5 well-scoped beat 10 overlapping.

## Fleet mode discipline

Fleet **collects** answers; it does not pick a winner. After the command returns, synthesize: state the consensus, surface disagreements (and which model held which view), and give one recommendation with reasoning. For `debate`, weigh the round-2 refined positions. Never paste five raw blocks back — the synthesized paragraph is the deliverable.

## Guardrails

Team workers edit real files autonomously — on an important repo, confirm scope first or point `--cwd` at a git worktree. Each CLI uses its own provider's API under its own auth; quintet adds no extra network destination.

Use the bundled slash commands `/quintet.doctor`, `/quintet.consult`, `/quintet.debate`, `/quintet.review`, and `/quintet.team` as shortcuts for the flows above.
