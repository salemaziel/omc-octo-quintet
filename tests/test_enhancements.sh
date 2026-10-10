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

# Role Taxonomy Verification
role_count="$("$BIN" roles --plain | wc -l)"
if [[ "$role_count" -eq 56 ]]; then
    ok "roles: master taxonomy exports 56 roles (stock + 55 expert personas)"
else
    bad "roles: expected 56 roles, got $role_count"
fi

if "$BIN" roles education | grep "ai-tutor-architect" >/dev/null && "$BIN" roles design | grep "web-designer" >/dev/null; then
    ok "roles: category filtering works (education, design)"
else
    bad "roles: category filtering failed"
fi

(
    source "$ROOT/lib/roles.sh"
    if quintet_role_exists "arch" && quintet_role_exists "socratic-tutor" && quintet_role_exists "marketing/copywriter"; then
        ok "roles: alias and namespaced resolution works"
    else
        bad "roles: alias resolution failed"
    fi

    if ! quintet_role_exists "../docs/x" && ! quintet_role_exists "nonexistent"; then
        ok "roles: path traversal and unknown role rejection works"
    else
        bad "roles: security rejection failed"
    fi
)

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

# ─────────────────────────────────────────────────────────────────────────────
echo "── 5. Interpretable Context Methodology (ICM) & Walk Test ──"

# Test ICM Worker Contract Generation
TEST_WDIR=$(mktemp -d "/tmp/quintet-test-icm-worker-XXXXXX")
TEST_CONTRACT="${TEST_WDIR}/CONTEXT.md"
TEST_STATUS="${TEST_WDIR}/status"
TEST_OUTDIR="${TEST_WDIR}/output"

"$BIN" walk non_existent_target >/dev/null 2>&1 || true

(
    source "$ROOT/lib/icm.sh"
    quintet_icm_write_worker_contract "$TEST_CONTRACT" "w1-codex" "codex" "implementer" \
        "Build auth system" "Implement JWT tokens" "$TEST_STATUS" "$TEST_OUTDIR" "src/auth/*.ts" "requirements.md"

    if [[ -f "$TEST_CONTRACT" ]] && grep -q "## Inputs" "$TEST_CONTRACT" && grep -q "## Human Check" "$TEST_CONTRACT"; then
        ok "icm: worker stage contract (CONTEXT.md) generated with all required sections"
    else
        bad "icm: worker contract generation failed"
    fi

    # Token / Size Discipline Check
    c_bytes="$(wc -c < "$TEST_CONTRACT")"
    if [[ "$c_bytes" -lt 8192 ]]; then
        ok "icm: worker contract satisfies token discipline (${c_bytes} bytes < 8 KB)"
    else
        bad "icm: worker contract exceeds token envelope (${c_bytes} bytes)"
    fi
)

# Test ICM Pipeline Lifecycle (init, status, advance, walk)
PIPE_NAME="test-pipe-$$"
out_pipe_init="$("$BIN" pipeline init "$PIPE_NAME" --template debate-build --goal "Build caching layer")"
if echo "$out_pipe_init" | grep -q "Pipeline initialized"; then
    ok "icm: pipeline init scaffolds numbered stages and root CONTEXT.md"
else
    bad "icm: pipeline init failed"
fi

    PIPE_STATE_DIR="${QUINTET_STATE_DIR:-${PWD}/.quintet}"
    PIPE_DIR="${PIPE_STATE_DIR}/pipelines/${PIPE_NAME}"
    if [[ -f "${PIPE_DIR}/stages/01_debate/CONTEXT.md" ]] && [[ -f "${PIPE_DIR}/stages/02_spec/CONTEXT.md" ]]; then
        ok "icm: stage contracts exist for numbered stages"
    else
        bad "icm: missing stage contracts"
    fi

    out_pipe_status="$("$BIN" pipeline status "$PIPE_NAME")"
    if echo "$out_pipe_status" | grep -q "01_debate" && echo "$out_pipe_status" | grep -q "02_spec"; then
        ok "icm: pipeline status reports numbered stages and artifacts"
    else
        bad "icm: pipeline status failed"
    fi

    out_pipe_adv="$("$BIN" pipeline advance "$PIPE_NAME")"
    if echo "$out_pipe_adv" | grep -q "Current active stage: 01_debate"; then
        ok "icm: pipeline advance identifies current active stage"
    else
        bad "icm: pipeline advance failed"
    fi

    # Simulate stage 1 artifact output (every output is an edit surface)
    echo "Consensus: Redis-backed distributed cache" > "${PIPE_DIR}/stages/01_debate/output/consensus.md"

    out_pipe_adv2="$("$BIN" pipeline advance "$PIPE_NAME" --auto)"
    if echo "$out_pipe_adv2" | grep -q "Current active stage: 02_spec"; then
        ok "icm: pipeline advances to stage 02 upon artifact completion"
    else
        bad "icm: pipeline advance to stage 02 failed"
    fi

    # Test ICM Walk Test
    out_walk="$("$BIN" walk "$PIPE_NAME")"
    if echo "$out_walk" | grep -q "passed the ICM Walk Test"; then
        ok "icm: walk test passes cold-agent auditability checks"
    else
        bad "icm: walk test failed: $out_walk"
    fi

    # Test Review Handoff to Pipeline Mode
    review_json='[{"provider":"claude","status":"0:ok","verdict":"changes_requested","findings":[{"file":"src/cache.ts","line":12,"severity":"high","message":"Unbounded key expiration"}]}]'
    out_handoff_pipe="$(printf '%s' "$review_json" | "$BIN" handoff review - --pipeline --name "pipe-rev-$$" --run)"
    if echo "$out_handoff_pipe" | grep -q "Review findings staged to"; then
        ok "handoff: --pipeline stages review findings as editable input for remediation"
    else
        bad "handoff: --pipeline mode failed"
    fi

    # Cleanup test pipeline directories
    rm -rf "$TEST_WDIR" "$PIPE_DIR" "${PIPE_STATE_DIR}/pipelines/pipe-rev-$$"

echo
echo "=== Test Results: ${PASS} passed, ${FAIL} failed ==="
if [[ "$FAIL" -eq 0 ]]; then
    echo "🎉 All tests passed successfully!"
    exit 0
else
    echo "❌ Some tests failed."
    exit 1
fi
