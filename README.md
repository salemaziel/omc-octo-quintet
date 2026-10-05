# quintet

**One orchestrator for multiple coding-agent CLIs.** Quintet drives **Claude Code**, **OpenAI Codex**, **Google Antigravity (agy)**, **GitHub Copilot**, **Qwen Code**, and **OpenCode** through a single entry point, in two complementary modes:

- **Team mode** — persistent worker processes in tmux panes that autonomously edit files and coordinate (the [oh-my-claudecode `omc-teams`](https://github.com/Yeachan-Heo/oh-my-claudecode) model, extended to Copilot, Qwen, and OpenCode).
- **Fleet mode** — one-shot dispatch of a single prompt to many CLIs in parallel, with a circuit-breaker + fallback reliability layer and `consult` / `debate` / `review` flows (the [claude-octopus](https://github.com/nyldn/claude-octopus) model).

It is **self-contained**: no runtime dependency on omc or octo. The two upstream projects each covered one half — quintet unifies persistent tmux teams *and* multi-provider one-shot dispatch across the full set of six CLIs.

## Why

| | omc-teams | claude-octopus | **quintet** |
| --- | --- | --- | --- |
| Persistent tmux worker teams | ✅ | ❌ | ✅ |
| One-shot multi-AI fleet / debate / review | ❌ | ✅ | ✅ |
| claude / codex / agy | ✅ | ✅ | ✅ |
| **copilot / qwen / opencode** | ❌ | ✅ (one-shot) | ✅ (**teams + one-shot**) |

The novel capability quintet adds: running **Copilot, Qwen, and OpenCode as persistent coordinating tmux team workers**, alongside Claude/Codex/Agy, under one CLI.

## Install

Quintet ships as a **plugin/extension for all major coding-agent CLIs** from one repo, distributed via the `vdw-claude-plugins` marketplace where supported.

**Claude Code** (marketplace):
```bash
/plugin marketplace add salemaziel/omc-octo-quintet
/plugin install quintet@vdw-claude-plugins
```

**OpenAI Codex** (marketplace): the repo ships `.agents/plugins/marketplace.json`. In Codex, run `/plugins`, switch to the `vdw-claude-plugins` marketplace tab, and install **quintet**.

**Antigravity CLI / Gemini** (plugin/extension):
```bash
agy plugin install https://github.com/salemaziel/omc-octo-quintet
# or legacy gemini: gemini extensions install https://github.com/salemaziel/omc-octo-quintet
```

**GitHub Copilot CLI** (plugin): point Copilot at the repo's root `plugin.json` (it loads `skills/` and the `.copilot/agents/` conductor). Verify with `/skills list` and `/agent`.

### The `quintet` binary — no PATH changes needed

Every ecosystem shells out to the same CLI at `bin/quintet`, **bundled inside the installed plugin** — quintet never touches your shell PATH. Each host locates it on its own:

- **Claude Code** runs it via the absolute `${CLAUDE_PLUGIN_ROOT}/bin/quintet`, and also exposes the plugin's `bin/` on the Bash tool's PATH only while the plugin is enabled (it does not modify your login shell).
- **Codex** sets `CLAUDE_PLUGIN_ROOT` for plugin compatibility, so the same skills resolve the binary there.
- **Antigravity / Gemini** finds it at `~/.gemini/config/plugins/quintet/bin/quintet` (or `~/.gemini/extensions/quintet/bin/quintet`).
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
# Google Antigravity CLI                   # agy
npm install -g @github/copilot             # copilot   (or: brew install copilot-cli)
npm install -g @qwen-code/qwen-code        # qwen      (free OAuth tier)
npm install -g @opencode/cli               # opencode  (or: curl -fsSL https://opencode.ai/install | bash)
```

## Usage

```bash
# Team mode — persistent tmux workers with optional subagent roles
quintet team 1:codex:implementer,1:agy:code-reviewer,1:claude:security-auditor "build auth feature" \
    --name auth-feat --cwd ./repo \
    --tasks "implement JWT auth endpoints||review logic and boundary safety||audit authz and injection vectors"
quintet team status auth-feat
quintet team capture auth-feat w1-codex-implementer 80
quintet team send auth-feat w2-agy-code-reviewer "focus on session expiration"
quintet team shutdown auth-feat --force

# Fleet mode — one-shot across many models (tmux session with live capture by default)
quintet consult "best way to dedupe a 10M-row stream?" claude,codex,agy
quintet debate  "gRPC or REST for this internal service?"
quintet review  "$(git diff HEAD~1)" claude,agy,copilot

# Non-tmux escape hatch
quintet fleet --no-tmux "quick advisory prompt" codex,claude

quintet doctor       # provider/tmux/jq readiness
quintet providers    # per-provider install/auth/ready
quintet roles        # list available subagent worker roles
```

### Slash commands (inside Claude Code)

`/quintet:team` · `/quintet:fleet` · `/quintet:consult` · `/quintet:debate` · `/quintet:review` · `/quintet:doctor`

### Agent

`quintet-conductor` — decomposes a task, picks providers and worker roles, launches/monitors a team or fleet, and synthesizes results.

## Configuration (env vars)

| Var | Purpose | Default |
| --- | --- | --- |
| `QUINTET_TIMEOUT` | global one-shot timeout (s) | 240 |
| `QUINTET_FLEET_TMUX` | run fleet dispatches in tmux | `true` (when tmux is available) |
| `QUINTET_<P>_TIMEOUT` | per-provider one-shot timeout | 90–240 |
| `QUINTET_<P>_LAUNCH` | interactive launch command for team workers | per provider |
| `QUINTET_<P>_ONESHOT_CMD` | override one-shot command for testing/sandboxes | per provider |
| `QUINTET_<P>_WARMUP` | seconds before injecting the task | 5–6 |
| `QUINTET_STATE_DIR` | team state dir | `$PWD/.quintet` |
| `QUINTET_HOME` | reliability/circuit-breaker state | `~/.quintet` |
| `QUINTET_CB_FAILURE_THRESHOLD` / `QUINTET_CB_COOLDOWN_SECS` | circuit breaker tuning | 3 / 300 |

`<P>` ∈ `CLAUDE CODEX AGY COPILOT QWEN OPENCODE`.

## Architecture

```
bin/quintet            CLI entry point + subcommand dispatch
lib/common.sh          logging, paths, slug/json helpers
lib/providers.sh       provider registry: detection, auth, one-shot + interactive contracts
lib/reliability.sh     error classification, circuit breaker, fallback
lib/roles.sh           subagent worker roles registry and prompt injection
lib/tmux.sh            detached-session / window / send-keys / capture helpers
lib/team.sh            persistent tmux worker-team runtime (N:provider:role)
lib/fleet.sh           one-shot parallel / consult / debate / review (tmux default)
roles/                 specialized role prompts (implementer, reviewer, security, etc.)
skills/                quintet-orchestration, quintet-team-runtime, quintet-fleet-dispatch
agents/                quintet-conductor
commands/              /quintet:{team,fleet,consult,debate,review,doctor}
```

Adding a provider (e.g. ollama, cursor-agent) = one entry in `QUINTET_PROVIDERS` plus its cases in `lib/providers.sh`. Nothing else hardcodes a CLI name.

## License

MIT.
