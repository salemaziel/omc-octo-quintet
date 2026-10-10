#!/usr/bin/env bash
# quintet/tests/test_enhancements.sh — verification test suite for recent architectural enhancements:
# 1. Macro-free skills & portable QBIN resolution
# 2. Headless worktrees lifecycle (start, status, merge, abort, list)
# 3. Two-phase handoff review automation
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${ROOT}/bin/quintet"
PASS=0
FAIL=0

ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

echo "=== Test Suite: Quintet Architectural Enhancements ==="
echo

# ─────────────────────────────────────────────────────────────────────────────
echo "── 1. Syntax & Macro Audit ──"
for f in "$ROOT"/bin/quintet "$ROOT"/lib/*.sh; do
    if bash -n "$f"; then
        ok "syntax: $(basename "$f")"
    else
        bad "syntax: $(basename "$f")"
    fi
done

# Check that skills contain zero !{ macros
if ! grep -rn "!{" "$ROOT"/skills/ >/dev/null 2>&1; then
    ok "skills: zero !{ macro occurrences found"
else
    bad "skills: found remaining !{ macro syntax"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "── 2. CLI Surface & Subcommand Registration ──"
if "$BIN" help | grep -q "WORKTREE MODE"; then
    ok "cli: help lists WORKTREE MODE"
else
    bad "cli: help missing WORKTREE MODE"
fi

if "$BIN" help | grep -q "HANDOFF AUTOMATION"; then
    ok "cli: help lists HANDOFF AUTOMATION"
else
    bad "cli: help missing HANDOFF AUTOMATION"
fi

if [[ "$("$BIN" worktrees list)" == "No active worktree teams."* ]]; then
    ok "cli: worktrees list works"
else
    bad "cli: worktrees list failed"
fi

if [[ "$("$BIN" worktree list)" == "No active worktree teams."* ]]; then
    ok "cli: worktree singular alias works"
else
    bad "cli: worktree singular alias failed"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "── 3. Two-Phase Handoff Automation (quintet handoff review) ──"
export QBIN="$BIN"

# Case A: Empty findings (Clean review)
clean_json='[{"provider":"claude","status":"0:ok","verdict":"approved","findings":[]}]'
out_clean="$(printf '%s' "$clean_json" | "$BIN" handoff review -)"
if echo "$out_clean" | grep -q "No remediation team needed"; then
    ok "handoff: clean review produces 'No remediation team needed'"
else
    bad "handoff: clean review handling failed"
fi

# Case B: Actionable findings grouping & disjoint task partitioning
findings_json='[
  {
    "provider": "claude",
    "status": "0:ok",
    "verdict": "changes_requested",
    "findings": [
      {"file": "src/auth/jwt.rs", "line": 42, "severity": "high", "message": "Token expiration timestamp is not validated"},
      {"file": "src/db/pool.rs", "line": 88, "severity": "medium", "message": "Connection pool max size missing"},
      {"file": "README.md", "line": 10, "severity": "low", "message": "Typo in header"}
    ]
  },
  {
    "provider": "codex",
    "status": "0:ok",
    "verdict": "changes_requested",
    "findings": [
      {"file": "src/auth/jwt.rs", "line": 42, "severity": "high", "message": "Token expiration timestamp is not validated"}
    ]
  }
]'

out_handoff="$(printf '%s' "$findings_json" | "$BIN" handoff review - --spec "1:codex:implementer,1:claude:implementer" --name "test-rev-fix" --min-severity "med")"

if echo "$out_handoff" | grep -q "Found 2 actionable findings across med+ severity:"; then
    ok "handoff: correctly filtered to 2 unique med+ findings (deduplicated high, excluded low)"
else
    bad "handoff: finding count filtering failed"
fi

if echo "$out_handoff" | grep -q -- "src/auth/jwt.rs:42" && echo "$out_handoff" | grep -q -- "src/db/pool.rs:88"; then
    ok "handoff: includes both target files"
else
    bad "handoff: target files missing from task formulation"
fi

if echo "$out_handoff" | grep -q "team " && echo "$out_handoff" | grep -q "1:codex:implementer" && echo "$out_handoff" | grep -q -- "--tasks"; then
    ok "handoff: correctly generated team command with --tasks argument"
else
    bad "handoff: generated command formatting failed"
fi

# Case C: Worktrees mode output
out_wt_handoff="$(printf '%s' "$findings_json" | "$BIN" handoff review - --spec "1:codex,1:claude" --mode worktrees --name "test-wt-fix")"
if echo "$out_wt_handoff" | grep -q "worktrees " && echo "$out_wt_handoff" | grep -q "1:codex"; then
    ok "handoff: --mode worktrees formats worktrees command"
else
    bad "handoff: --mode worktrees failed"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "── 4. Headless Worktrees Lifecycle (quintet worktrees) ──"

TEST_REPO="$(mktemp -d)"
trap 'rm -rf "$TEST_REPO"' EXIT

(
    cd "$TEST_REPO"
    git init -q -b main
    git config user.name "test-user"
    git config user.email "test@example.com"
    echo "initial" > base.txt
    git add base.txt
    git commit -q -m "initial commit"
)

# Start worktrees in test repo
WT_NAME="mock-wt-$$"
(
    cd "$TEST_REPO"
    "$BIN" worktrees start "1:codex:implementer,1:claude:implementer" "implement mock features" \
        --name "$WT_NAME" \
        --tasks "create fileA.txt in worktree||create fileB.txt in worktree" \
        --no-tmux \
        --skip-auth-check >/dev/null 2>&1
)

if [[ -d "$TEST_REPO/.worktrees/$WT_NAME/w1-codex-implementer" ]] && [[ -d "$TEST_REPO/.worktrees/$WT_NAME/w2-claude-implementer" ]]; then
    ok "worktrees: worktree directories created for all workers"
else
    bad "worktrees: failed to create worktree directories"
fi

if [[ -f "$TEST_REPO/.worktrees/$WT_NAME/w1-codex-implementer/.brief.txt" ]]; then
    ok "worktrees: brief file written to worktree"
else
    bad "worktrees: brief file missing"
fi

# Check status command
out_status="$(cd "$TEST_REPO" && "$BIN" worktrees status "$WT_NAME")"
if echo "$out_status" | grep -q "Worktree Team: $WT_NAME"; then
    ok "worktrees: status outputs team status table"
else
    bad "worktrees: status output failed"
fi

# Simulate worker edits in each worktree
(
    cd "$TEST_REPO/.worktrees/$WT_NAME/w1-codex-implementer"
    echo "content from worker 1" > fileA.txt
    git add fileA.txt
    git commit -q -m "feat: worker 1 changes"
)
(
    cd "$TEST_REPO/.worktrees/$WT_NAME/w2-claude-implementer"
    echo "content from worker 2" > fileB.txt
    git add fileB.txt
    git commit -q -m "feat: worker 2 changes"
)

# Merge worktrees
out_merge="$(cd "$TEST_REPO" && "$BIN" worktrees merge "$WT_NAME" --branch "integration-branch" 2>&1)"
if echo "$out_merge" | grep -q "All worker branches merged cleanly into 'integration-branch'"; then
    ok "worktrees: merge combines disjoint worker commits into integration branch"
else
    bad "worktrees: merge command failed: $out_merge"
fi

# Verify merged contents on integration branch
if ( cd "$TEST_REPO" && git checkout -q integration-branch && [[ -f fileA.txt ]] && [[ -f fileB.txt ]] ); then
    ok "worktrees: both worker files exist on integration branch"
else
    bad "worktrees: missing files on integration branch"
fi

# Verify worktrees cleanup
if [[ ! -d "$TEST_REPO/.worktrees/$WT_NAME" ]]; then
    ok "worktrees: worktrees cleaned up after merge"
else
    bad "worktrees: cleanup failed after merge"
fi

echo
echo "=== Test Results: ${PASS} passed, ${FAIL} failed ==="
if [[ "$FAIL" -eq 0 ]]; then
    echo "🎉 All tests passed successfully!"
    exit 0
else
    echo "❌ Some tests failed."
    exit 1
fi
