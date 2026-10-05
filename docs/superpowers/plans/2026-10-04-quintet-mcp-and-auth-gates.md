# Quintet: MCP Controls, Pre-Flight Auth Gates, and Host Command Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement first-class `--no-mcp` server toggles across provider CLIs, pre-flight authentication/readiness validation in Team mode to prevent deadlocked worker panes, and add the missing `/fleet.toml` command for Antigravity/Gemini CLI parity.

**Architecture:**
1. `lib/providers.sh`: Extend `quintet_provider_launch_cmd` and `quintet_provider_oneshot` to accept MCP isolation flags (`--no-mcp`), translating to provider-specific arguments (`--strict-mcp-config` for Claude, `--disable-builtin-mcps` for Copilot, `--pure` for OpenCode, etc.).
2. `lib/team.sh`: In `quintet_team_start`, run pre-flight authentication verification on every parsed provider using `quintet_provider_ready`. Abort early with clear diagnostic output before creating tmux windows (with `--force` / `--skip-auth-check` override for test harnesses).
3. `lib/fleet.sh`: Pass `--no-mcp` through `_quintet_fan_out` to provider invocations.
4. `commands/fleet.toml`: Add dedicated fleet command manifest for AGY/Gemini extension parity alongside `/consult.toml`.
5. `tests/smoke.sh`: Add smoke tests for pre-flight auth checking, `--no-mcp` argument handling, and TOML command validity.

**Tech Stack:** Bash, Tmux, TOML, Git.

## Global Constraints

- Must run under bash 4+ and POSIX tools; maintain compatibility across Linux and macOS.
- Pre-flight auth checks must not break test harnesses using stand-in worker shells (e.g. `QUINTET_CLAUDE_LAUNCH='bash --norc'`).
- `--no-mcp` must be an optional flag that defaults to preserving normal agent MCP environment unless requested.
- All commands in `commands/*.toml` must be valid TOML recognized by AGY extension loaders.

---

### Task 1: Pre-Flight Auth Readiness Gates in Team Mode (`lib/team.sh`)

**Files:**
- Modify: `lib/team.sh:54-65`
- Modify: `tests/smoke.sh`

**Interfaces:**
- `quintet_team_start <spec> <task> [--skip-auth-check] [--cwd DIR] ...`
  - Validates `quintet_provider_ready "$provider"` for every worker in the spec.
  - If a provider is not authenticated and no mock launch override is set (`QUINTET_<P>_LAUNCH`), abort with `die "team start: provider '$provider' is not authenticated. Run: quintet doctor"`.

- [ ] **Step 1: Write failing smoke test for pre-flight auth rejection**
  Add a test in `tests/smoke.sh` attempting to spawn an unauthenticated provider in team mode and asserting that it fails before creating a tmux session.
- [ ] **Step 2: Run test and verify failure**
  Confirm test fails (current code attempts to create tmux session regardless of auth).
- [ ] **Step 3: Implement pre-flight auth check in `quintet_team_start`**
  Check readiness of each parsed provider, allowing `--skip-auth-check` or `QUINTET_<P>_LAUNCH` overrides.
- [ ] **Step 4: Run test and verify it passes**
  Run `bash tests/smoke.sh`.
- [ ] **Step 5: Commit**
  `git add lib/team.sh tests/smoke.sh && git commit -m "feat(team): add pre-flight provider authentication check before pane spawn"`

---

### Task 2: Per-Agent MCP Server Toggling (`--no-mcp`) (`lib/providers.sh`, `lib/fleet.sh`, `lib/team.sh`)

**Files:**
- Modify: `lib/providers.sh:135-210`
- Modify: `lib/fleet.sh`
- Modify: `lib/team.sh`
- Modify: `bin/quintet`
- Modify: `tests/smoke.sh`

**Interfaces:**
- `quintet_provider_launch_cmd <provider> [--no-mcp]` -> returns launch command with MCP disabled flags.
- `quintet_provider_oneshot <provider> <prompt> [--no-mcp]` -> passes MCP disabling flags to headless CLI.
- Flags: `--no-mcp` accepted in `quintet team`, `quintet fleet`, `quintet consult`, `quintet debate`, `quintet review`.
- Environment variable: `QUINTET_NO_MCP=true` global toggle.

- [ ] **Step 1: Write failing smoke tests for `--no-mcp` flag propagation**
  Test that `quintet_provider_launch_cmd "claude" --no-mcp` includes `--strict-mcp-config` and `copilot` includes `--disable-builtin-mcps`.
- [ ] **Step 2: Run test and verify failure**
  Run `bash tests/smoke.sh`.
- [ ] **Step 3: Implement MCP flags in `lib/providers.sh` and CLI parsers**
  Update provider launch builders to add MCP-suppressing flags when `--no-mcp` is passed or `QUINTET_NO_MCP=true`.
- [ ] **Step 4: Run tests and verify they pass**
  Run `bash tests/smoke.sh`.
- [ ] **Step 5: Commit**
  `git add lib/providers.sh lib/fleet.sh lib/team.sh bin/quintet tests/smoke.sh && git commit -m "feat(mcp): support --no-mcp flag across fleet and team runtimes"`

---

### Task 3: AGY / Gemini Command Parity (`commands/fleet.toml` and manifest)

**Files:**
- Create: `commands/fleet.toml`
- Modify: `gemini-extension.json`
- Modify: `tests/smoke.sh`

**Interfaces:**
- `/fleet` command available in AGY/Gemini CLI with prompt and provider arguments.

- [ ] **Step 1: Write failing test verifying all commands in `commands/*.toml` are registered in `gemini-extension.json`**
  Add assertion in `tests/smoke.sh` that `commands/fleet.toml` exists and is declared in `gemini-extension.json`.
- [ ] **Step 2: Run test and verify failure**
  Confirm test fails on missing `fleet.toml`.
- [ ] **Step 3: Create `commands/fleet.toml` and update `gemini-extension.json`**
  Add TOML definition for `/fleet` and register in `gemini-extension.json`.
- [ ] **Step 4: Run test and verify it passes**
  Run `bash tests/smoke.sh`.
- [ ] **Step 5: Commit**
  `git add commands/fleet.toml gemini-extension.json tests/smoke.sh && git commit -m "feat(gemini): add fleet command TOML for AGY parity"`

---

### Task 4: Documentation & Skills Sync

**Files:**
- Modify: `skills/quintet-fleet-dispatch/SKILL.md`
- Modify: `skills/quintet-team-runtime/SKILL.md`
- Modify: `README.md`

- [ ] **Step 1: Document `--no-mcp` flag and pre-flight auth checks**
  Update CLI tables and usage examples in skills and README.
- [ ] **Step 2: Run full smoke test suite**
  Execute `bash tests/smoke.sh`.
- [ ] **Step 3: Commit**
  `git add skills/ README.md && git commit -m "docs: document --no-mcp flag and pre-flight auth checks"`
