# Quintet: Audit Completion (Models, Watchdog, Pruning, Safety) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the remaining architectural recommendations from `quintet-audit-report.md`: model & reasoning effort configuration, automated modal/stalled-worker watchdog diagnostics, state pruning & garbage collection (`quintet prune`), and a tiered permission/safety mode (`--safe`).

**Architecture:**
1. `lib/providers.sh`: Support model selection (`--model <m>`) and reasoning effort (`--effort <e>`), configuring provider CLIs (`claude`, `codex`, `agy`, `copilot`, `qwen`, `opencode`) via flags and environment variables (`QUINTET_<P>_MODEL`, `QUINTET_<P>_EFFORT`, `QUINTET_MODEL`, `QUINTET_EFFORT`). Add `--safe` mode toggling to omit blanket bypass flags.
2. `lib/team.sh`: In `quintet team status <name>` and new `quintet team doctor <name>`, inspect recent pane buffer text for interactive confirmation modals (trust folder, tool call approval, login dialogs), reporting blocked workers with recovery commands. Support `N:provider:role:model` spec parsing.
3. `lib/prune.sh` & `bin/quintet`: Implement `quintet prune [--days N] [--force]` to garbage-collect defunct team state dirs, abandoned sessions, and aged debate transcripts.
4. `tests/smoke.sh`: Extend test suite to verify model configuration, watchdog modal detection, pruning lifecycle, and safety mode flags.

**Tech Stack:** Bash, Tmux, Git.

## Global Constraints

- Must run under Bash 4+ and POSIX tools across Linux and macOS.
- Must preserve 100% backward compatibility: existing `N:provider` and `N:provider:role` syntax continues to work unchanged.
- Smoke tests must remain non-destructive and mock external API calls to avoid token consumption.
- All Git commits and pushes must use the enforced identity `salemaziel <mymainemail0501@gmail.com>`.

---

### Task 1: Model Selection & Reasoning Effort Controls (`lib/providers.sh`, `lib/team.sh`, `lib/fleet.sh`, `bin/quintet`)

**Files:**
- Modify: `lib/providers.sh`
- Modify: `lib/team.sh`
- Modify: `lib/fleet.sh`
- Modify: `bin/quintet`
- Modify: `tests/smoke.sh`

**Interfaces:**
- `quintet_provider_launch_cmd <provider> [no_mcp] [model] [effort] [safe_mode]`
- `quintet_provider_oneshot <provider> <prompt> [no_mcp] [model] [effort] [safe_mode]`
- Extended spec syntax: `N:provider[:role][:model]` (e.g. `1:codex:implementer:o3-mini`, `1:claude::sonnet`, `1:agy:code-reviewer:gemini-2.5-pro`).
- CLI flags: `--model <name>`, `--effort <low|medium|high|xhigh|max>`.
- Env vars: `QUINTET_<P>_MODEL`, `QUINTET_<P>_EFFORT`, `QUINTET_MODEL`, `QUINTET_EFFORT`.

- [x] **Step 1: Write failing smoke tests for model and reasoning effort resolution**
  Assert that `quintet_provider_launch_cmd "codex" false "o3-mini" "high"` emits `codex --yolo --model o3-mini -c model_reasoning_effort=high`, and `agy` emits `--model gemini-2.5-pro --effort high`.
- [x] **Step 2: Run test and verify failure**
  Run `bash tests/smoke.sh`.
- [x] **Step 3: Implement model and effort options in `lib/providers.sh` and spec parser in `lib/team.sh`**
  Extend `_quintet_parse_spec` to extract optional 4th token `model`, and update launch/oneshot builders.
- [x] **Step 4: Propagate flags through `lib/fleet.sh` and `bin/quintet`**
  Support `--model` and `--effort` in `quintet fleet`, `consult`, `debate`, `review`, and `team`.
- [x] **Step 5: Run tests and verify they pass**
  Run `bash tests/smoke.sh`.
- [x] **Step 6: Commit**
  `git add lib/providers.sh lib/team.sh lib/fleet.sh bin/quintet tests/smoke.sh && git commit -m "feat(models): support model selection and reasoning effort across providers and spec syntax"`

---

### Task 2: Stalled Worker & Modal Watchdog (`lib/team.sh`, `lib/tmux.sh`, `bin/quintet`)

**Files:**
- Modify: `lib/team.sh`
- Modify: `bin/quintet`
- Modify: `tests/smoke.sh`

**Interfaces:**
- `quintet_team_check_modals <team_name>`: Inspects recent pane lines of every worker in a team.
- Detection patterns:
  - Trust folder dialogs: `Do you trust this folder?` / `Trust folder`
  - Tool approval dialogs: `Allow tool call?` / `[y/N]` / `approve.*tool`
  - Auth/login dialogs: `Login required` / `Sign in` / `authenticate`
  - Paused execution: `Press Enter to continue` / `Press any key`
- `quintet team status <name>`: Annotates blocked workers with `⚠️  STALLED_MODAL: <type>` and recovery hints.
- `quintet team doctor <name>`: Subcommand dedicated to running pane diagnostics and offering autofix/intervention.

- [x] **Step 1: Write failing smoke tests for modal watchdog detection**
  Simulate a worker pane printing a mock `Do you trust this folder? [y/N]` prompt and verify that `quintet team status` flags it as modal-blocked.
- [x] **Step 2: Run test and verify failure**
  Run `bash tests/smoke.sh`.
- [x] **Step 3: Implement modal scanner in `lib/team.sh`**
  Add helper `_quintet_detect_worker_modal "$team" "$worker"` and integrate into `quintet_team_status` and `cmd_team_doctor`.
- [x] **Step 4: Register `quintet team doctor <name>` in `bin/quintet`**
  Wire subcommand in `bin/quintet`.
- [x] **Step 5: Run tests and verify they pass**
  Run `bash tests/smoke.sh`.
- [x] **Step 6: Commit**
  `git add lib/team.sh bin/quintet tests/smoke.sh && git commit -m "feat(watchdog): add interactive modal detection and team doctor diagnostics"`

---

### Task 3: State Pruning & Garbage Collection (`lib/prune.sh`, `bin/quintet`)

**Files:**
- Create: `lib/prune.sh`
- Modify: `bin/quintet`
- Modify: `tests/smoke.sh`

**Interfaces:**
- `quintet prune [--days N] [--dry-run] [--force]`
  - Scans `${QUINTET_STATE_DIR}/teams/` for directories whose tmux session has terminated.
  - Scans `${QUINTET_HOME}/debates/` for transcripts older than N days (default: 7 days).
  - Cleans up dead socket files and temporary run files.
  - Outputs summary of reclaimed space and removed entries.

- [x] **Step 1: Write failing smoke tests for `quintet prune`**
  Create a simulated dead team directory and an aged debate directory; assert `quintet prune --days 0` cleans them up.
- [x] **Step 2: Run test and verify failure**
  Run `bash tests/smoke.sh`.
- [x] **Step 3: Implement `lib/prune.sh` and wire `quintet prune` in `bin/quintet`**
  Create `lib/prune.sh` with safe deletion checks and register in `bin/quintet`.
- [x] **Step 4: Run tests and verify they pass**
  Run `bash tests/smoke.sh`.
- [x] **Step 5: Commit**
  `git add lib/prune.sh bin/quintet tests/smoke.sh && git commit -m "feat(prune): add quintet prune garbage collection for stale teams and debates"`

---

### Task 4: Tiered Permission / Safety Mode (`--safe`) (`lib/providers.sh`, `lib/team.sh`, `lib/fleet.sh`)

**Files:**
- Modify: `lib/providers.sh`
- Modify: `lib/team.sh`
- Modify: `lib/fleet.sh`
- Modify: `bin/quintet`
- Modify: `tests/smoke.sh`

**Interfaces:**
- `--safe` flag / `QUINTET_SAFE_MODE=true` env var.
- Provider behavior in safe mode:
  - Claude: uses default permission mode (no `--permission-mode bypassPermissions`).
  - Codex: no `--yolo`.
  - Agy: no `--dangerously-skip-permissions`.
  - Copilot: no `--allow-all-tools`.
  - Qwen: no `--approval-mode yolo`.
  - OpenCode: no `--auto`.

- [x] **Step 1: Write failing smoke tests for `--safe` flag in `lib/providers.sh`**
  Assert that `quintet_provider_launch_cmd "claude" false "" "" true` omits `bypassPermissions`, and `codex` omits `--yolo`.
- [x] **Step 2: Run test and verify failure**
  Run `bash tests/smoke.sh`.
- [x] **Step 3: Implement `--safe` mode handling in `lib/providers.sh`, `lib/team.sh`, and `lib/fleet.sh`**
  Condition blanket autonomy flags on `safe_mode != true`.
- [x] **Step 4: Run tests and verify they pass**
  Run `bash tests/smoke.sh`.
- [x] **Step 5: Commit**
  `git add lib/providers.sh lib/team.sh lib/fleet.sh bin/quintet tests/smoke.sh && git commit -m "feat(security): support --safe mode omitting blanket autonomy flags"`

---

### Task 5: Documentation & Skills Sync

**Files:**
- Modify: `skills/quintet-team-runtime/SKILL.md`
- Modify: `skills/quintet-fleet-dispatch/SKILL.md`
- Modify: `README.md`
- Modify: `CONTEXT.md`

- [x] **Step 1: Document all new commands, flags, and spec syntax**
  Update CLI usage, configuration tables, and skill guides with `--model`, `--effort`, `quintet team doctor`, `quintet prune`, and `--safe`.
- [x] **Step 2: Run full smoke test suite**
  Execute `bash tests/smoke.sh`.
- [x] **Step 3: Commit and Push**
  `git add skills/ README.md CONTEXT.md docs/superpowers/plans/ && git commit -m "docs: document models, watchdog, prune, and safe mode capabilities"`
