# Agent Instructions for Quintet (`omc-octo-quintet`)

## ⛔ CRITICAL: Testing Policy — DO NOT RUN TESTS AUTOMATICALLY

- **NEVER run `tests/smoke.sh` unprompted or as a completion/verification gate.**
- `tests/smoke.sh` is an expensive, heavyweight (>1200 lines) tmux integration test suite that spawns virtual tmux servers and takes minutes to run.
- **Do NOT run it for:**
  - Version bumps, manifest updates, metadata changes.
  - Documentation, markdown notes, README changes.
  - Small bug fixes, refactoring, or CLI tweaks.
- Only run `tests/smoke.sh` if the user explicitly commands: *"run the smoke tests"*.
- For routine verification, use lightweight tools:
  - `bash -n <script>` to verify shell syntax.
  - `git diff` to inspect changes.
  - Conclude the turn directly without running any test suites.

## Multi-Agent Architecture
- **CLI Entry Point:** `bin/quintet`
- **Provider Registry:** `lib/providers.sh` (Claude, Codex, Agy, Copilot, Qwen, OpenCode)
- **Runtimes:** `lib/team.sh` (tmux worker teams), `lib/fleet.sh` (one-shot parallel dispatches), `lib/prune.sh`
- **Skills:** `skills/` (orchestration, team runtime, fleet dispatch, consult, debate, review, doctor)
