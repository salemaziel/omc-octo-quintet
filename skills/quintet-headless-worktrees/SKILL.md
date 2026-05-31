---
name: quintet-headless-worktrees
description: Orchestrate multiple coding-agent CLIs (codex/gemini/copilot/claude) headlessly — each in its own git worktree, driven non-interactively, then merged. Use when fanning real implementation or review work out to several model CLIs in parallel without a tmux REPL, when you need worktree isolation so agents don't collide, or when distributing token cost onto external providers. Trigger on "run codex/gemini/copilot in parallel", "headless multi-agent", "git worktree per agent", "non-interactive CLI agents", "offload work to other model CLIs", "parallel build with isolated worktrees". For interactive tmux worker teams use quintet-team-runtime instead; for one-shot opinions use quintet-fleet-dispatch.
---

# Quintet Headless Worktrees

Drive several coding-agent CLIs as **one-shot, non-interactive processes** (`codex exec`, `gemini -p`, `copilot -p`), each confined to its **own git worktree**, then verify and merge their commits. The orchestrator (you) decomposes, dispatches, reviews, and integrates; the worker CLIs spend their own provider's tokens doing the work.

## When to use this vs. the alternatives

- **This skill** — you want agents to *write code or produce review artifacts* in parallel, reliably, with file-level isolation, and you do **not** want to babysit interactive REPLs. Headless `exec` avoids the single biggest flake source of REPL teams: the **warmup-swallow** (the first task sent to a cold interactive CLI is often eaten).
- `quintet-team-runtime` — long-lived interactive tmux workers you steer over time.
- `quintet-fleet-dispatch` — one-shot opinions/reviews, no files written.

The deciding question: *do agents mutate files in parallel and need isolation + clean merges?* If yes, this skill.

## The core model

```
base commit ── wt1 (agent A) ─┐
            ── wt2 (agent B) ─┤  octopus-merge → integration branch → verify → push
            ── wt3 (agent C) ─┘
```

One worktree per work package, **partitioned by disjoint file ownership** so branches never touch the same file. That single design choice is what makes parallel agents produce clean merges instead of conflict soup. Cross-cutting files that *no* package owns (a shared config, a site-wide token) are the **orchestrator's** to edit during integration — assign them to nobody and a holistic review will later flag the gap.

## Primitive 1 — Headless invocation (per-CLI)

Non-interactive mode is the reliability win. Each CLI has an auto-approve flag; without it the process blocks forever waiting for a confirmation it can't receive.

| CLI | Headless form | Auto-approve |
|-----|---------------|--------------|
| codex | `codex exec -C <dir> [PROMPT or -]` | `-s workspace-write` (sandboxed) |
| gemini | `gemini -p "<prompt>"` | `--yolo` (or `--approval-mode yolo`) |
| copilot | `copilot -p "<prompt>"` | `--allow-all` |

`codex exec` reads the prompt from a positional arg, from stdin via `-`, or piped. gemini/copilot take the prompt on `-p` and run in the current directory (so `cd` into the worktree, or for codex use `-C <dir>`).

## Primitive 2 — Worktree setup (and the symlink trap)

```bash
git worktree add -b <branch> <dir> <base>
ln -s "$REPO/node_modules" "<dir>/node_modules"   # share deps; never reinstall
cp "$REPO/.env" "<dir>/.env"                       # gitignored secrets the build needs
```
Tell every agent **"do not run `npm install` — `node_modules` is a symlink"**, or a sandboxed install will either fail or duplicate hundreds of MB per worktree.

**The trap:** `.gitignore` with `node_modules/` (trailing slash) matches a *directory*, **not a symlink** named `node_modules`. So `git add -A` will stage the symlink into the commit, and merging it later creates a self-referential tracked symlink that collides with the real dir on checkout. Two defenses, use both:
- Instruct agents to stage **explicit paths only** (`git add src/foo.ts`), never `git add -A`/`.`.
- Add `node_modules` (no slash) to the repo's `.git/info/exclude`.

After every agent finishes, **verify the commit touched only owned files** and amend out any leak.

## Primitive 3 — The brief-file pattern (quoting hazard)

Real task briefs contain quotes, backticks, `<>`, `$` — interpolating them into a shell `-p "..."` arg corrupts the command or triggers command substitution. **Don't pass the brief on the command line.** Write it to a file *inside the worktree* and give a tiny literal prompt:

```bash
cp brief.txt "<dir>/.brief.txt"            # exclude it from git too
codex exec -C "<dir>" -s workspace-write "Read ./.brief.txt and follow it exactly."
```
The CLI opens the file with its own read tool. Zero shell-escaping risk, and the brief can be arbitrarily long/complex.

## Primitive 4 — Sandbox & commit gotchas (codex)

- **Avoid `--dangerously-bypass-approvals-and-sandbox`.** A safety classifier (and good sense) will block it. Use sandboxed write instead: `-s workspace-write -c sandbox_workspace_write.network_access=true` — confined to the worktree, but with network for build-time fetches. A blanket "I approve everything" from the user does **not** override the bypass block; sandboxed mode is what actually runs.
- **Linked-worktree commit fails with `EROFS` / `index.lock: Read-only file system`.** A linked worktree's git index lives in the *main* repo's `.git/worktrees/<name>/`, which is **outside** the worktree sandbox. So a sandboxed codex can edit files and run the build, but **cannot `git commit`**. Plan for it: the agent's edits land **uncommitted in the working tree** — the orchestrator (unsandboxed) builds, scans, and commits them. gemini `--yolo` / copilot `--allow-all` are *not* filesystem-sandboxed this way and commit fine.

## Primitive 5 — Review-then-fix, on the worker's tokens

The point of external CLIs is **token distribution**: keep the orchestrator (your own model) for coordination/verification, and push review *and the resulting fixes* onto the provider CLIs. A review that only reports, then makes the orchestrator implement, defeats the purpose.

- **Read-only review** still needs `workspace-write` (the agent writes its *report file*); instruct "modify no source; write findings to `./REPORT.md`."
- Run **independent holistic passes** from different model CLIs over the *integrated* tree — they catch cross-file inconsistencies single-package reviews structurally can't (e.g., the one file nobody owned).
- Triage findings against scope. Fix in-scope a11y/security/correctness; **defer pre-existing, out-of-scope items** rather than scope-creeping.

## Primitive 6 — Concurrency hazards

- **Two CLIs building in the same directory corrupt `dist/`.** Either give each its own worktree, or **pre-build once yourself** and tell reviewers "a build already exists in `./dist`; do not rebuild."
- Launch independent agents as parallel background jobs. One denied/blocked launch in a batch can cancel its siblings — isolate a risky launch (e.g. an untested flag) into its own probe first.

## Primitive 7 — Integration & verification

- Merge disjoint-file branches with an **octopus merge** (`git merge b1 b2 b3 ...`); disjoint files → no conflicts.
- **Never trust a worker's "exit 0."** For every branch verify, in order: (1) commit scope = owned files only; (2) no `node_modules`/brief/secret leak in the diff; (3) `npm run build` green on the *integrated* tree; (4) **grep the build output for secret values** (build-time secrets must not reach client bundles).
- Reject **environment-specific patches** an agent adds to make *its sandbox* pass (e.g., redirecting cache dirs) — those are slop, not improvements. Commit the real fix, discard the workaround.

## Primitive 8 — Secret hygiene

CLI tools that load env (e.g. `netlify env:import`) often **echo the values back to stdout** — a leak into your transcript/logs. Pipe through a mask, or prefer file-based imports that don't print values, and if a secret does surface, tell the user to **rotate it**.

## Failure-mode quick reference

| Symptom | Cause | Fix |
|---|---|---|
| First task ignored | interactive REPL warmup-swallow | use headless `exec`/`-p`, not a REPL |
| codex won't commit (`EROFS`) | git index outside worktree sandbox | orchestrator commits the agent's edits |
| `--dangerously-bypass…` denied | safety classifier | `-s workspace-write -c sandbox_workspace_write.network_access=true` |
| `node_modules` symlink in commit | `node_modules/` ignore ≠ symlink | explicit `git add`; add `node_modules` to exclude |
| command mangled / substituted | quotes/backticks in `-p` arg | brief-file pattern |
| `dist/` corrupted | concurrent builds, same dir | pre-build once; reviewers don't rebuild |
| deployed site "code works but does nothing" | gitignored `.env` absent from CI build env | set env vars in the deploy platform; rebuild |
