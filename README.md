# quintet

**One orchestrator for five coding-agent CLIs.** Quintet drives **Claude Code**, **OpenAI Codex**, **Google Gemini**, **GitHub Copilot**, and **Qwen Code** through a single entry point, in two complementary modes:

- **Team mode** — persistent worker processes in tmux panes that autonomously edit files and coordinate (the [oh-my-claudecode `omc-teams`](https://github.com/Yeachan-Heo/oh-my-claudecode) model, extended to Copilot and Qwen).
- **Fleet mode** — one-shot dispatch of a single prompt to many CLIs in parallel, with a circuit-breaker + fallback reliability layer and `consult` / `debate` / `review` flows (the [claude-octopus](https://github.com/nyldn/claude-octopus) model).

It is **self-contained**: no runtime dependency on omc or octo. The two upstream projects each covered one half — quintet unifies persistent tmux teams *and* multi-provider one-shot dispatch across the full set of five CLIs.

## Why

| | omc-teams | claude-octopus | **quintet** |
| --- | --- | --- | --- |
| Persistent tmux worker teams | ✅ | ❌ | ✅ |
| One-shot multi-AI fleet / debate / review | ❌ | ✅ | ✅ |
| claude / codex / gemini | ✅ | ✅ | ✅ |
| **copilot / qwen** | ❌ | ✅ (one-shot) | ✅ (**teams + one-shot**) |

The novel capability quintet adds: running **Copilot and Qwen as persistent coordinating tmux team workers**, alongside Claude/Codex/Gemini, under one CLI.

## Install

Quintet ships as a **plugin/extension for all four major coding-agent CLIs** from one repo, distributed via the `vdw-claude-plugins` marketplace where supported.

**Claude Code** (marketplace):
```bash
/plugin marketplace add salemaziel/omc-octo-quintet
/plugin install quintet@vdw-claude-plugins
```

**OpenAI Codex** (marketplace): the repo ships `.agents/plugins/marketplace.json`. In Codex, run `/plugins`, switch to the `vdw-claude-plugins` marketplace tab, and install **quintet**.

**Gemini CLI** (extension):
```bash
gemini extensions install https://github.com/salemaziel/omc-octo-quintet
```

**GitHub Copilot CLI** (plugin): point Copilot at the repo's root `plugin.json` (it loads `skills/` and the `.copilot/agents/` conductor). Verify with `/skills list` and `/agent`.

### The `quintet` binary — no PATH changes needed

Every ecosystem shells out to the same CLI at `bin/quintet`, **bundled inside the installed plugin** — quintet never touches your shell PATH. Each host locates it on its own:

- **Claude Code** runs it via the absolute `${CLAUDE_PLUGIN_ROOT}/bin/quintet`, and also exposes the plugin's `bin/` on the Bash tool's PATH only while the plugin is enabled (it does not modify your login shell).
- **Codex** sets `CLAUDE_PLUGIN_ROOT` for plugin compatibility, so the same skills resolve the binary there.
- **Gemini** finds it at `~/.gemini/extensions/quintet/bin/quintet`.
- **Copilot** finds it under `~/.copilot/installed-plugins/.../quintet/bin/quintet`.

Optional — only if you also want to run `quintet` by hand in a normal terminal:

```bash
ln -s "$PWD/bin/quintet" ~/.local/bin/quintet   # standalone CLI use, not required by any plugin
quintet doctor
```

Requirements: `tmux` (team mode only), `jq` (optional), and at least one of the agent CLIs installed and authenticated:

```bash
npm install -g @anthropic-ai/claude-code   # claude
npm install -g @openai/codex               # codex
npm install -g @google/gemini-cli          # gemini
npm install -g @github/copilot             # copilot   (or: brew install copilot-cli)
npm install -g @qwen-code/qwen-code        # qwen      (free OAuth tier)
```

## Usage

```bash
# Team mode — persistent tmux workers
quintet team 2:codex,1:gemini,1:qwen "build the export feature" \
    --name export --cwd ./repo \
    --tasks "implement serializer||add tests||write docs||audit edge cases"
quintet team status export
quintet team capture export w1-codex 80
quintet team send export w2-gemini "focus on the v2 API"
quintet team shutdown export --force

# Fleet mode — one-shot across many models
quintet consult "best way to dedupe a 10M-row stream?" claude,codex,gemini
quintet debate  "gRPC or REST for this internal service?"
quintet review  "$(git diff HEAD~1)" claude,gemini,copilot

quintet doctor       # provider/tmux/jq readiness
quintet providers    # per-provider install/auth/ready
```

### Slash commands (inside Claude Code)

`/quintet:team` · `/quintet:fleet` · `/quintet:consult` · `/quintet:debate` · `/quintet:review` · `/quintet:doctor`

### Agent

`quintet-conductor` — decomposes a task, picks providers, launches/monitors a team or fleet, and synthesizes results.

## Configuration (env vars)

| Var | Purpose | Default |
| --- | --- | --- |
| `QUINTET_TIMEOUT` | global one-shot timeout (s) | 120 |
| `QUINTET_<P>_TIMEOUT` | per-provider one-shot timeout | 90–120 |
| `QUINTET_<P>_LAUNCH` | interactive launch command for team workers | per provider |
| `QUINTET_<P>_WARMUP` | seconds before injecting the task | 5–6 |
| `QUINTET_STATE_DIR` | team state dir | `$PWD/.quintet` |
| `QUINTET_HOME` | reliability/circuit-breaker state | `~/.quintet` |
| `QUINTET_CB_FAILURE_THRESHOLD` / `QUINTET_CB_COOLDOWN_SECS` | circuit breaker tuning | 3 / 300 |

`<P>` ∈ `CLAUDE CODEX GEMINI COPILOT QWEN`.

## Architecture

```
bin/quintet            CLI entry point + subcommand dispatch
lib/common.sh          logging, paths, slug/json helpers
lib/providers.sh       provider registry: detection, auth, one-shot + interactive contracts
lib/reliability.sh     error classification, circuit breaker, fallback
lib/tmux.sh            detached-session / window / send-keys / capture helpers
lib/team.sh            persistent tmux worker-team runtime
lib/fleet.sh           one-shot parallel / consult / debate / review
skills/                quintet-orchestration, quintet-team-runtime, quintet-fleet-dispatch
agents/                quintet-conductor
commands/              /quintet:{team,fleet,consult,debate,review,doctor}
```

Adding a provider (e.g. ollama, cursor-agent) = one entry in `QUINTET_PROVIDERS` plus its cases in `lib/providers.sh`. Nothing else hardcodes a CLI name.

## License

MIT.
