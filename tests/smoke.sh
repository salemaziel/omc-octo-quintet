#!/usr/bin/env bash
# quintet/tests/smoke.sh — non-destructive smoke test of the runtime.
# Verifies syntax, doctor/providers, and the full tmux team lifecycle using a
# harmless shell as a stand-in worker (no real agent API calls / no quota burn).
# Run: tests/smoke.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${ROOT}/bin/quintet"
PASS=0; FAIL=0
ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

echo "── 1. syntax ──"
for f in "$ROOT"/lib/*.sh "$BIN"; do
    bash -n "$f" && ok "syntax: $(basename "$f")" || bad "syntax: $(basename "$f")"
done

echo "── 2. cli surface ──"
"$BIN" version  >/dev/null 2>&1 && ok "version" || bad "version"
"$BIN" help     >/dev/null 2>&1 && ok "help"    || bad "help"
"$BIN" providers >/dev/null 2>&1 && ok "providers" || bad "providers"
"$BIN" doctor   >/dev/null 2>&1; [[ $? -le 1 ]] && ok "doctor runs" || bad "doctor runs"

echo "── 3. tmux team lifecycle (shell stand-in workers) ──"
if ! command -v tmux >/dev/null 2>&1; then
    echo "  ⚠️  tmux not installed — skipping team lifecycle"
else
    export QUINTET_STATE_DIR; QUINTET_STATE_DIR="$(mktemp -d)"
    export QUINTET_CLAUDE_LAUNCH='bash --norc' QUINTET_CLAUDE_WARMUP=2
    T="smoke-$$"
    "$BIN" team 2:claude "smoke" --name "$T" --cwd /tmp >/dev/null 2>&1 && ok "team start" || bad "team start"
    sleep 3
    "$BIN" team status "$T" >/dev/null 2>&1 && ok "team status" || bad "team status"
    marker="/tmp/quintet-smoke-$$.txt"; rm -f "$marker"
    "$BIN" team send "$T" "w1-claude" "echo OK > $marker" >/dev/null 2>&1
    sleep 2
    [[ -f "$marker" ]] && ok "worker executed injected task" || bad "worker executed injected task"
    [[ -f "${QUINTET_STATE_DIR}/teams/${T}/team.json" ]] && ok "manifest written" || bad "manifest written"
    "$BIN" team shutdown "$T" --force >/dev/null 2>&1 && ok "team shutdown" || bad "team shutdown"
    tmux has-session -t "quintet-$T" 2>/dev/null && bad "session cleaned" || ok "session cleaned"
    rm -f "$marker"; rm -rf "$QUINTET_STATE_DIR"
fi

echo
echo "── result: ${PASS} passed, ${FAIL} failed ──"
[[ "$FAIL" -eq 0 ]]
