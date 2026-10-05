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
[[ -f "$ROOT/commands/fleet.toml" ]] && ok "commands/fleet.toml exists" || bad "commands/fleet.toml exists"
grep -q 'description' "$ROOT/commands/fleet.toml" 2>/dev/null && ok "fleet.toml has description" || bad "fleet.toml has description"

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
source "${ROOT}/lib/roles.sh"
source "${ROOT}/lib/team.sh"
source "${ROOT}/lib/fleet.sh"
[[ "$(_quintet_parse_spec "1:gemini")" == "agy:stock" ]] && ok "spec parses gemini -> agy:stock" || bad "spec parses gemini -> agy:stock"
[[ "$(_quintet_parse_spec "1:agy")" == "agy:stock" ]] && ok "spec parses agy -> agy:stock" || bad "spec parses agy -> agy:stock"
[[ "$(quintet_provider_bin "agy")" == "agy" ]] && ok "bin for agy is agy" || bad "bin for agy is agy"
[[ "$(quintet_provider_bin "gemini")" == "agy" ]] && ok "bin for gemini alias is agy" || bad "bin for gemini alias is agy"

echo "── 2c. opencode provider & spec resolution ──"
[[ "$(_quintet_parse_spec "1:opencode")" == "opencode:stock" ]] && ok "spec parses opencode -> opencode:stock" || bad "spec parses opencode -> opencode:stock"
[[ "$(quintet_provider_bin "opencode")" == "opencode" ]] && ok "bin for opencode is opencode" || bad "bin for opencode is opencode"
[[ "$(quintet_provider_emoji "opencode")" == "🟧" ]] && ok "emoji for opencode is 🟧" || bad "emoji for opencode is 🟧"
[[ "$(quintet_provider_launch_cmd "opencode")" == "opencode --auto" ]] && ok "launch cmd for opencode is opencode --auto" || bad "launch cmd for opencode"

echo "── 2d. subagent roles ──"
quintet_role_exists "implementer" && ok "role exists: implementer" || bad "role exists: implementer"
quintet_role_exists "stock" && ok "role exists: stock" || bad "role exists: stock"
quintet_role_exists "nonexistent_role" && bad "nonexistent role should not exist" || ok "nonexistent role rejected"
[[ -n "$(quintet_role_prompt "implementer")" ]] && ok "role prompt returned for implementer" || bad "role prompt returned for implementer"
[[ -z "$(quintet_role_prompt "stock")" ]] && ok "role prompt empty for stock" || bad "role prompt empty for stock"
[[ "$(_quintet_parse_spec "1:agy:implementer")" == "agy:implementer" ]] && ok "spec parses 1:agy:implementer" || bad "spec parses 1:agy:implementer"
[[ "$(_quintet_parse_spec "2:codex:reviewer")" == $'codex:code-reviewer\ncodex:code-reviewer' ]] && ok "spec parses 2:codex:reviewer with alias" || bad "spec parses 2:codex:reviewer with alias"

echo "── 2e. per-agent mcp toggles ──"
[[ "$(quintet_provider_launch_cmd "claude" --no-mcp)" == *"strict-mcp-config"* ]] && ok "claude launch with --no-mcp disables MCP" || bad "claude launch with --no-mcp disables MCP"
[[ "$(quintet_provider_launch_cmd "codex" --no-mcp)" == *"mcp_servers={}"* ]] && ok "codex launch with --no-mcp overrides mcp_servers" || bad "codex launch with --no-mcp overrides mcp_servers"
[[ "$(quintet_provider_launch_cmd "copilot" --no-mcp)" == *"--disable-builtin-mcps"* ]] && ok "copilot launch with --no-mcp disables MCP" || bad "copilot launch with --no-mcp disables MCP"
[[ "$(quintet_provider_launch_cmd "opencode" --no-mcp)" == *"--pure"* ]] && ok "opencode launch with --no-mcp runs pure" || bad "opencode launch with --no-mcp runs pure"
QUINTET_NO_MCP=true
[[ "$(quintet_provider_launch_cmd "claude")" == *"strict-mcp-config"* ]] && ok "QUINTET_NO_MCP=true disables MCP by default" || bad "QUINTET_NO_MCP=true disables MCP by default"
unset QUINTET_NO_MCP

echo "── 2f. model & reasoning effort resolution ──"
[[ "$(quintet_provider_launch_cmd "codex" false "o3-mini" "high")" == *"codex --yolo --model o3-mini -c model_reasoning_effort=high"* ]] && ok "codex launch with model & effort" || bad "codex launch with model & effort"
[[ "$(quintet_provider_launch_cmd "agy" false "gemini-2.5-pro" "high")" == *"agy --dangerously-skip-permissions --model gemini-2.5-pro --effort high"* ]] && ok "agy launch with model & effort" || bad "agy launch with model & effort"
[[ "$(quintet_provider_launch_cmd "claude" false "sonnet" "medium")" == *"claude --permission-mode bypassPermissions --model sonnet --effort medium"* ]] && ok "claude launch with model & effort" || bad "claude launch with model & effort"
[[ "$(_quintet_parse_spec "1:codex:implementer:o3-mini")" == "codex:implementer:o3-mini" ]] && ok "spec parses 1:codex:implementer:o3-mini" || bad "spec parses 1:codex:implementer:o3-mini"
[[ "$(_quintet_parse_spec "1:claude::haiku")" == "claude:stock:haiku" ]] && ok "spec parses 1:claude::haiku with stock default" || bad "spec parses 1:claude::haiku with stock default"

echo "── 2g. tiered permissions & safety mode (--safe) ──"
[[ "$(quintet_provider_launch_cmd "claude" false "" "" true)" != *"bypassPermissions"* ]] && ok "safe mode omits claude bypassPermissions" || bad "safe mode omits claude bypassPermissions"
[[ "$(quintet_provider_launch_cmd "codex" false "" "" true)" != *"--yolo"* ]] && ok "safe mode omits codex --yolo" || bad "safe mode omits codex --yolo"
[[ "$(quintet_provider_launch_cmd "agy" false "" "" true)" != *"--dangerously-skip-permissions"* ]] && ok "safe mode omits agy --dangerously-skip-permissions" || bad "safe mode omits agy --dangerously-skip-permissions"
[[ "$(quintet_provider_launch_cmd "copilot" false "" "" true)" != *"--allow-all-tools"* ]] && ok "safe mode omits copilot --allow-all-tools" || bad "safe mode omits copilot --allow-all-tools"
[[ "$(quintet_provider_launch_cmd "qwen" false "" "" true)" != *"--approval-mode yolo"* ]] && ok "safe mode omits qwen --approval-mode yolo" || bad "safe mode omits qwen --approval-mode yolo"
[[ "$(quintet_provider_launch_cmd "opencode" false "" "" true)" != *"--auto"* ]] && ok "safe mode omits opencode --auto" || bad "safe mode omits opencode --auto"
QUINTET_SAFE_MODE=true
[[ "$(quintet_provider_launch_cmd "claude")" != *"bypassPermissions"* ]] && ok "QUINTET_SAFE_MODE=true disables bypassPermissions" || bad "QUINTET_SAFE_MODE=true disables bypassPermissions"
unset QUINTET_SAFE_MODE

echo "── 3. tmux team lifecycle (shell stand-in workers) ──"
if ! command -v tmux >/dev/null 2>&1; then
    echo "  ⚠️  tmux not installed — skipping team lifecycle"
else
    # Pre-flight auth checks
    auth_err=$("$BIN" team 1:qwen "fail task" --name "smoke-auth-fail-$$" --cwd /tmp 2>&1 || true)
    echo "$auth_err" | grep -q "not ready/authenticated" && ok "pre-flight auth rejects unready provider" || bad "pre-flight auth rejects unready provider"
    tmux has-session -t "quintet-smoke-auth-fail-$$" 2>/dev/null && bad "pre-flight session created on failure" || ok "no session created on auth failure"

    export QUINTET_QWEN_LAUNCH='bash --norc' QUINTET_QWEN_WARMUP=1
    "$BIN" team 1:qwen "skip auth" --name "smoke-auth-skip-$$" --skip-auth-check --cwd /tmp >/dev/null 2>&1 || true
    tmux has-session -t "quintet-smoke-auth-skip-$$" 2>/dev/null && ok "--skip-auth-check permits start" || bad "--skip-auth-check permits start"
    "$BIN" team shutdown "smoke-auth-skip-$$" --force >/dev/null 2>&1 || true
    unset QUINTET_QWEN_LAUNCH QUINTET_QWEN_WARMUP

    export QUINTET_STATE_DIR; QUINTET_STATE_DIR="$(mktemp -d)"
    export QUINTET_CLAUDE_LAUNCH='bash --norc' QUINTET_CLAUDE_WARMUP=2
    T="smoke-$$"
    "$BIN" team 1:claude:implementer,1:claude:stock "smoke" --name "$T" --cwd /tmp --no-mcp --safe >/dev/null 2>&1 && ok "team start" || bad "team start"
    sleep 3
    "$BIN" team status "$T" >/dev/null 2>&1 && ok "team status" || bad "team status"
    marker="/tmp/quintet-smoke-$$.txt"; rm -f "$marker"
    "$BIN" team send "$T" "w1-claude-implementer" "echo OK > $marker" >/dev/null 2>&1
    sleep 2
    [[ -f "$marker" ]] && ok "worker executed injected task" || bad "worker executed injected task"
    grep -E -q '"role"[[:space:]]*:[[:space:]]*"implementer"' "${QUINTET_STATE_DIR}/teams/${T}/team.json" 2>/dev/null && ok "manifest records role" || bad "manifest records role"
    grep -q '"no_mcp": true' "${QUINTET_STATE_DIR}/teams/${T}/team.json" 2>/dev/null && ok "manifest records no_mcp" || bad "manifest records no_mcp"
    grep -q '"safe_mode": true' "${QUINTET_STATE_DIR}/teams/${T}/team.json" 2>/dev/null && ok "manifest records safe_mode" || bad "manifest records safe_mode"
    grep -q 'role: implementer' "${QUINTET_STATE_DIR}/teams/${T}/taskboard.md" 2>/dev/null && ok "taskboard records role" || bad "taskboard records role"
    [[ -f "${QUINTET_STATE_DIR}/teams/${T}/team.json" ]] && ok "manifest written" || bad "manifest written"

    # Watchdog modal detection
    "$BIN" team send "$T" "w2-claude" "printf 'Do you trust this folder? [y/N]: '" >/dev/null 2>&1
    sleep 1
    status_out=$("$BIN" team status "$T" 2>&1 || true)
    echo "$status_out" | grep -q "STALLED_MODAL: TRUST_FOLDER" && ok "team status flags modal stall" || bad "team status flags modal stall"

    doctor_out=$("$BIN" team doctor "$T" 2>&1 || true)
    echo "$doctor_out" | grep -q "STALLED on modal: TRUST_FOLDER" && ok "team doctor reports stalled modal" || bad "team doctor reports stalled modal"
    echo "$doctor_out" | grep -q "Remediation:" && ok "team doctor gives remediation" || bad "team doctor gives remediation"

    "$BIN" team shutdown "$T" --force >/dev/null 2>&1 && ok "team shutdown" || bad "team shutdown"
    tmux has-session -t "quintet-$T" 2>/dev/null && bad "session cleaned" || ok "session cleaned"
    rm -f "$marker"; rm -rf "$QUINTET_STATE_DIR"
fi

echo "── 3c. state pruning & garbage collection ──"
fake_state="$(mktemp -d)"
fake_home="$(mktemp -d)"
mkdir -p "${fake_state}/teams/dead-team-1"
mkdir -p "${fake_home}/debates/old-debate-1"
echo '{"name":"dead-team-1"}' > "${fake_state}/teams/dead-team-1/team.json"
echo '# Old debate' > "${fake_home}/debates/old-debate-1/transcript.md"

QUINTET_STATE_DIR="$fake_state" QUINTET_HOME="$fake_home" "$BIN" prune --days 0 >/dev/null 2>&1 && ok "prune runs successfully" || bad "prune runs successfully"
[[ ! -d "${fake_state}/teams/dead-team-1" ]] && ok "prune removed dead team" || bad "prune removed dead team"
[[ ! -d "${fake_home}/debates/old-debate-1" ]] && ok "prune removed aged debate" || bad "prune removed aged debate"
rm -rf "$fake_state" "$fake_home"

echo "── 4. fleet tmux & fallback execution ──"
export QUINTET_CLAUDE_ONESHOT_CMD='echo "mock claude fleet answer"'
out_notmux=$("$BIN" fleet --no-tmux "test prompt" claude 2>&1)
echo "$out_notmux" | grep -q "mock claude fleet answer" && ok "fleet --no-tmux executed" || bad "fleet --no-tmux executed"

out_nomcp=$("$BIN" fleet --no-tmux --no-mcp "test prompt" claude 2>&1)
echo "$out_nomcp" | grep -q "mock claude fleet answer" && ok "fleet --no-mcp executed" || bad "fleet --no-mcp executed"

if command -v tmux >/dev/null 2>&1; then
    out_tmux=$("$BIN" fleet "test prompt" claude 2>&1)
    echo "$out_tmux" | grep -q "mock claude fleet answer" && ok "fleet tmux execution succeeded" || bad "fleet tmux execution succeeded"
    echo "$out_tmux" | grep -q "Tmux session:" && ok "fleet outputs tmux attach command" || bad "fleet outputs tmux attach command"
fi

echo
echo "── result: ${PASS} passed, ${FAIL} failed ──"
[[ "$FAIL" -eq 0 ]]
