# Quintet: Tmux Execution by Default & Subagent Worker Roles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement default tmux session execution for fleet mode and headless worktrees (with non-tmux escape hatch), subagent worker role definitions with `N:provider:role` vs. `stock` spec syntax, and prominent tmux attach command display.

**Architecture:** 
1. `lib/roles.sh`: Role registry and markdown template loader (`roles/*.md`). Maps role names (`implementer`, `code-reviewer`, `security-auditor`, `test-engineer`, `debugger`, `devops-troubleshooter`, `stock`) to prompt guidelines.
2. `lib/team.sh`: Update `_quintet_parse_spec` to parse `N:provider:role` (and `N:provider`), inject role instructions into worker launch prompts, and record role attributes in `team.json` and `taskboard.md`.
3. `lib/fleet.sh`: Introduce tmux execution path as default for fleet fan-out (`QUINTET_FLEET_TMUX=true` default when tmux is available; `--no-tmux` or `QUINTET_FLEET_TMUX=false` escape hatch). Display `tmux attach -t quintet-fleet-<id>` during execution.
4. `roles/`: Standard library of reusable worker role markdown files.
5. `tests/smoke.sh`: Extended smoke test suite verifying role spec parsing, role prompt injection, fleet tmux execution, and `--no-tmux` fallback.

**Tech Stack:** Bash, Tmux, POSIX shell utilities, Git.

## Global Constraints

- Must run under bash 4+ and POSIX tools; maintain compatibility across Linux and macOS.
- Never break existing `N:provider` spec syntax (e.g. `2:claude,1:agy`); default role must be `stock`.
- Fleet mode must retain `--no-tmux` escape hatch and automatically fall back if `tmux` is not installed or errors.
- Always output clean `tmux attach -t <session>` commands for user visibility.
- Tests in `tests/smoke.sh` must remain self-contained, offline-safe (mock shells / stand-in workers), and exit 0.

---

### Task 1: Subagent Role Definitions & Loader (`lib/roles.sh` and `roles/*.md`)

**Files:**
- Create: `roles/implementer.md`
- Create: `roles/code-reviewer.md`
- Create: `roles/security-auditor.md`
- Create: `roles/test-engineer.md`
- Create: `roles/debugger.md`
- Create: `roles/devops-troubleshooter.md`
- Create: `lib/roles.sh`
- Modify: `bin/quintet:14-20`
- Modify: `tests/smoke.sh`

**Interfaces:**
- `quintet_role_exists <role>` -> returns 0 if role exists or is "stock", 1 otherwise.
- `quintet_role_prompt <role>` -> prints the instructions for `<role>`, or empty if "stock".
- `quintet_role_list` -> lists available role names.

- [ ] **Step 1: Write failing smoke tests for role resolution**
  In `tests/smoke.sh`, add a section `── 2d. subagent roles ──` testing `quintet_role_exists`, `quintet_role_prompt`, and `quintet_role_list`.
- [ ] **Step 2: Run smoke tests and verify failure**
  Run `bash tests/smoke.sh` and confirm failure on missing `lib/roles.sh`.
- [ ] **Step 3: Create `roles/*.md` templates**
  Write structured, discipline-focused markdown prompts for `implementer`, `code-reviewer`, `security-auditor`, `test-engineer`, `debugger`, and `devops-troubleshooter`.
- [ ] **Step 4: Implement `lib/roles.sh` and source in `bin/quintet`**
  Implement `quintet_role_exists`, `quintet_role_prompt`, and `quintet_role_list`. Handle case insensitivity and aliases (e.g. `reviewer` -> `code-reviewer`).
- [ ] **Step 5: Run tests and verify they pass**
  Run `bash tests/smoke.sh` and ensure all role tests pass.
- [ ] **Step 6: Commit**
  `git add roles/ lib/roles.sh bin/quintet tests/smoke.sh && git commit -m "feat(roles): add subagent role definitions and role loader"`

---

### Task 2: Extend Spec Parser & Worker Prompt Injection in Team Mode (`lib/team.sh`)

**Files:**
- Modify: `lib/team.sh:13-31` (`_quintet_parse_spec`)
- Modify: `lib/team.sh:94-138` (`quintet_team_start`)
- Modify: `tests/smoke.sh`

**Interfaces:**
- `_quintet_parse_spec <spec>` -> emits lines in format `provider:role` (e.g., `codex:implementer`, `agy:stock`).
- `quintet_team_start` -> displays `tmux attach -t quintet-<team>` and injects role instructions into prompt payload.

- [ ] **Step 1: Write failing smoke tests for extended spec parsing and role injection**
  Test `_quintet_parse_spec "1:codex:implementer,2:agy,1:claude:code-reviewer"`. Verify provider and role extraction and `taskboard.md` formatting.
- [ ] **Step 2: Run smoke tests and verify failure**
  Verify that the old parser fails on 3-part tokens.
- [ ] **Step 3: Update `_quintet_parse_spec` and `quintet_team_start`**
  Update parser to support `count:provider:role` and `count:provider` (defaulting role to `stock`).
  In `quintet_team_start`, resolve role prompt via `quintet_role_prompt` and prepend to the injected agent instructions. Include role in manifest `team.json` and `taskboard.md`.
  Ensure `tmux attach -t quintet-<team>` is printed clearly.
- [ ] **Step 4: Run tests and verify they pass**
  Run `bash tests/smoke.sh`.
- [ ] **Step 5: Commit**
  `git add lib/team.sh tests/smoke.sh && git commit -m "feat(team): support N:provider:role spec syntax and role prompt injection"`

---

### Task 3: Tmux Execution by Default for Fleet Mode (`lib/fleet.sh`)

**Files:**
- Modify: `lib/fleet.sh:128-190`
- Modify: `lib/tmux.sh`
- Modify: `tests/smoke.sh`

**Interfaces:**
- `_quintet_fan_out <prompt> <provider-arg> [--no-tmux]`
  - Runs in tmux session `quintet-fleet-<ts>-<id>` by default when `tmux` is available and `QUINTET_FLEET_TMUX` != `false`.
  - Prints `log INFO "Fleet session: tmux attach -t quintet-fleet-<id>"`
  - Waits for worker completion, extracts output to `${rundir}/${p}.out`, and tears down session.
  - Falls back seamlessly to subshell fan-out if `--no-tmux` is passed, `QUINTET_FLEET_TMUX=false`, or tmux creation fails.

- [ ] **Step 1: Write failing smoke test for fleet tmux execution and fallback**
  Add tests for `_quintet_fan_out` running in tmux with mock providers and `--no-tmux` override.
- [ ] **Step 2: Run smoke tests and verify failure**
  Confirm test fails without fleet tmux implementation.
- [ ] **Step 3: Implement tmux fan-out in `lib/fleet.sh` and tmux helpers in `lib/tmux.sh`**
  Implement `_quintet_fleet_fan_out_tmux` and flag parsing for `--no-tmux` / `--tmux`.
  Log the tmux attach command for user visibility.
- [ ] **Step 4: Run tests and verify they pass**
  Run `bash tests/smoke.sh`.
- [ ] **Step 5: Commit**
  `git add lib/fleet.sh lib/tmux.sh tests/smoke.sh && git commit -m "feat(fleet): run fleet dispatches in tmux by default with fallback"`

---

### Task 4: Headless Worktrees Tmux Support & Skill Documentation Update

**Files:**
- Modify: `skills/quintet-headless-worktrees/SKILL.md`
- Modify: `skills/quintet-team-runtime/SKILL.md`
- Modify: `skills/quintet-orchestration/SKILL.md`
- Modify: `README.md`

- [ ] **Step 1: Update documentation and skills for `N:provider:role` spec syntax**
  Document the `N:provider:role` syntax across skills and command references.
- [ ] **Step 2: Update headless worktrees guidance for tmux default execution**
  Document the tmux-first pattern for headless worktree dispatches with `tmux attach` visibility and non-tmux escape hatch.
- [ ] **Step 3: Run full verification suite**
  Run `bash tests/smoke.sh`.
- [ ] **Step 4: Commit**
  `git add skills/ README.md && git commit -m "docs(skills): document subagent worker roles and tmux fleet defaults"`
