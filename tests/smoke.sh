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
"$BIN" providers | grep "agy" >/dev/null && ok "providers lists agy" || bad "providers lists agy"
"$BIN" providers | grep "opencode" >/dev/null && ok "providers lists opencode" || bad "providers lists opencode"
"$BIN" roles     >/dev/null 2>&1 && ok "roles" || bad "roles"
"$BIN" roles | grep "implementer" >/dev/null && ok "roles lists implementer" || bad "roles lists implementer"
"$BIN" doctor   >/dev/null 2>&1; [[ $? -le 1 ]] && ok "doctor runs" || bad "doctor runs"

echo "── 2b. agy provider & alias resolution ──"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/providers.sh"
source "${ROOT}/lib/team.sh"
source "${ROOT}/lib/fleet.sh"
[[ "$(_quintet_parse_spec "1:gemini")" == "agy" ]] && ok "spec parses gemini -> agy" || bad "spec parses gemini -> agy"
[[ "$(_quintet_parse_spec "1:agy")" == "agy" ]] && ok "spec parses agy" || bad "spec parses agy"
[[ "$(quintet_provider_bin "agy")" == "agy" ]] && ok "bin for agy is agy" || bad "bin for agy is agy"
[[ "$(quintet_provider_bin "gemini")" == "agy" ]] && ok "bin for gemini alias is agy" || bad "bin for gemini alias is agy"

echo "── 2c. opencode provider & spec resolution ──"
[[ "$(_quintet_parse_spec "1:opencode")" == "opencode" ]] && ok "spec parses opencode" || bad "spec parses opencode"
[[ "$(quintet_provider_bin "opencode")" == "opencode" ]] && ok "bin for opencode is opencode" || bad "bin for opencode is opencode"
[[ "$(quintet_provider_emoji "opencode")" == "🟧" ]] && ok "emoji for opencode is 🟧" || bad "emoji for opencode is 🟧"
[[ "$(quintet_provider_launch_cmd "opencode")" == "opencode --auto" ]] && ok "launch cmd for opencode is opencode --auto" || bad "launch cmd for opencode"

echo "── 2d. subagent roles ──"
source "${ROOT}/lib/roles.sh"
quintet_role_exists "implementer" && ok "role exists: implementer" || bad "role exists: implementer"
quintet_role_exists "stock" && ok "role exists: stock" || bad "role exists: stock"
quintet_role_exists "nonexistent_role" && bad "nonexistent role should not exist" || ok "nonexistent role rejected"
[[ -n "$(quintet_role_prompt "implementer")" ]] && ok "role prompt returned for implementer" || bad "role prompt returned for implementer"
[[ -z "$(quintet_role_prompt "stock")" ]] && ok "role prompt empty for stock" || bad "role prompt empty for stock"

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
