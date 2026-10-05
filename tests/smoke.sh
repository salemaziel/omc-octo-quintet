#!/usr/bin/env bash
# quintet/tests/smoke.sh — non-destructive smoke test of the runtime.
# Verifies syntax, doctor/providers, and the full tmux team lifecycle using a
# harmless shell as a stand-in worker (no real agent API calls / no quota burn).
# Run: tests/smoke.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${ROOT}/bin/quintet"
PASS=0; FAIL=0

# Test isolation: every tmux call (quintet's qtmux and this script's ttmux) goes
# to a private server, never the user's default one. Killed on exit.
export QUINTET_TMUX_SOCKET="quintet-test-$$"
unset TMUX
ttmux() { tmux -L "$QUINTET_TMUX_SOCKET" "$@"; }
trap 'tmux -L "$QUINTET_TMUX_SOCKET" kill-server >/dev/null 2>&1; rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$QUINTET_TMUX_SOCKET"' EXIT
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
# launch strings are %q-escaped argv: eval back into an array to check elements.
eval "la=($(quintet_provider_launch_cmd "codex" --no-mcp))"
[[ " ${la[*]} " == *" -c mcp_servers={} "* ]] && ok "codex launch with --no-mcp overrides mcp_servers" || bad "codex launch with --no-mcp overrides mcp_servers"
[[ "$(quintet_provider_launch_cmd "copilot" --no-mcp)" == *"--disable-builtin-mcps"* ]] && ok "copilot launch with --no-mcp disables MCP" || bad "copilot launch with --no-mcp disables MCP"
oc_err=$(quintet_provider_launch_cmd "opencode" --no-mcp 2>&1 >/dev/null); oc_out=$(quintet_provider_launch_cmd "opencode" --no-mcp 2>/dev/null)
[[ "$oc_out" != *"--pure"* ]] && echo "$oc_err" | grep -q "WARN.*opencode: --no-mcp not supported" && ok "opencode --no-mcp: no --pure, WARN instead (A8)" || bad "opencode --no-mcp: no --pure, WARN instead (A8)"
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
[[ "$(quintet_provider_launch_cmd "copilot" false "" "" true)" != *"--allow-all"* ]] && ok "safe mode omits copilot --allow-all" || bad "safe mode omits copilot --allow-all"
[[ "$(quintet_provider_launch_cmd "qwen" false "" "" true)" != *"--approval-mode yolo"* ]] && ok "safe mode omits qwen --approval-mode yolo" || bad "safe mode omits qwen --approval-mode yolo"
[[ "$(quintet_provider_launch_cmd "opencode" false "" "" true)" != *"--auto"* ]] && ok "safe mode omits opencode --auto" || bad "safe mode omits opencode --auto"
QUINTET_SAFE_MODE=true
[[ "$(quintet_provider_launch_cmd "claude")" != *"bypassPermissions"* ]] && ok "QUINTET_SAFE_MODE=true disables bypassPermissions" || bad "QUINTET_SAFE_MODE=true disables bypassPermissions"
unset QUINTET_SAFE_MODE

echo "── 3. tmux team lifecycle (shell stand-in workers) ──"
if ! command -v tmux >/dev/null 2>&1; then
    echo "  ⚠️  tmux not installed — skipping team lifecycle"
else
    # Pre-flight auth checks (state in a sandbox, never the repo's ./.quintet)
    export QUINTET_STATE_DIR; QUINTET_STATE_DIR="$(mktemp -d)"
    auth_err=$("$BIN" team 1:qwen "fail task" --name "smoke-auth-fail-$$" --cwd /tmp 2>&1 || true)
    echo "$auth_err" | grep -q "not ready/authenticated" && ok "pre-flight auth rejects unready provider" || bad "pre-flight auth rejects unready provider"
    ttmux has-session -t "quintet-smoke-auth-fail-$$" 2>/dev/null && bad "pre-flight session created on failure" || ok "no session created on auth failure"

    export QUINTET_QWEN_LAUNCH='bash --norc' QUINTET_QWEN_WARMUP=1
    "$BIN" team 1:qwen "skip auth" --name "smoke-auth-skip-$$" --skip-auth-check --cwd /tmp >/dev/null 2>&1 || true
    ttmux has-session -t "quintet-smoke-auth-skip-$$" 2>/dev/null && ok "--skip-auth-check permits start" || bad "--skip-auth-check permits start"
    "$BIN" team shutdown "smoke-auth-skip-$$" --force >/dev/null 2>&1 || true
    unset QUINTET_QWEN_LAUNCH QUINTET_QWEN_WARMUP
    rm -rf "$QUINTET_STATE_DIR"

    QUINTET_STATE_DIR="$(mktemp -d)"
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
    ttmux has-session -t "quintet-$T" 2>/dev/null && bad "session cleaned" || ok "session cleaned"
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

echo "── 5. input validation & argument guards ──"
V="$(mktemp -d)"
export QUINTET_STATE_DIR="$V/proj/.quintet"
mkdir -p "$QUINTET_STATE_DIR/teams" "$QUINTET_STATE_DIR/x"
export QUINTET_CLAUDE_LAUNCH='bash --norc' QUINTET_CLAUDE_WARMUP=1
# no_sessions <pattern> — true if no session on the test socket matches.
no_sessions() { ! ttmux list-sessions -F '#{session_name}' 2>/dev/null | grep -q -- "$1"; }

# M7 / C6: a bad later token must abort the whole team (no partial start).
out=$("$BIN" team 1:claude,1:codex:a:b:c "t" --name "smoke-spec5-$$" --skip-auth-check --cwd /tmp 2>&1); rc=$?
[[ $rc -eq 1 ]] && echo "$out" | grep -q "too many fields" && ok "team spec with 5 fields dies" || bad "team spec with 5 fields dies"
no_sessions "smoke-spec5-$$" && ok "no session after 5-field spec" || bad "no session after 5-field spec"
out=$("$BIN" team 1:claude,1:bogus "t" --name "smoke-bogus-$$" --skip-auth-check --cwd /tmp 2>&1); rc=$?
[[ $rc -eq 1 ]] && echo "$out" | grep -q "unsupported provider" && ok "team spec with bogus provider dies" || bad "team spec with bogus provider dies"
no_sessions "smoke-bogus-$$" && ok "no session after bogus-provider spec" || bad "no session after bogus-provider spec"
( _quintet_parse_spec "1:codex:stock:model:extra" ) >/dev/null 2>&1 && bad "parser rejects 5 fields" || ok "parser rejects 5 fields"
[[ "$(_quintet_parse_spec "1:claude:stock:haiku")" == "claude:stock:haiku" ]] && ok "parser keeps 4 fields" || bad "parser keeps 4 fields"

# A1 / A3: team names are validated everywhere.
out=$("$BIN" team shutdown ../x --force 2>&1); rc=$?
[[ $rc -eq 1 ]] && echo "$out" | grep -q "invalid team name" && ok "shutdown ../x --force dies" || bad "shutdown ../x --force dies"
[[ -d "$QUINTET_STATE_DIR/x" ]] && ok "traversal target survives shutdown" || bad "traversal target survives shutdown"
for sub in status doctor capture send; do
    "$BIN" team "$sub" ../x w1 hi >/dev/null 2>&1; rc=$?
    [[ $rc -eq 1 ]] && ok "team $sub rejects ../x" || bad "team $sub rejects ../x"
done
long_name="$(printf 'a%.0s' {1..65})"
for bad_name in "a.b" "a:b" "$long_name" "-lead"; do
    out=$("$BIN" team 1:claude "t" --name "$bad_name" --skip-auth-check --cwd /tmp 2>&1); rc=$?
    [[ $rc -eq 1 ]] && echo "$out" | grep -q "invalid team name" && ok "--name '${bad_name:0:12}' rejected" || bad "--name '${bad_name:0:12}' rejected"
done
no_sessions "quintet-a" && ok "no session for rejected names" || bad "no session for rejected names"

# M2: missing positionals / flag values give clean errors (no set -u crash).
out=$("$BIN" team 1:claude 2>&1); rc=$?
[[ $rc -eq 1 ]] && echo "$out" | grep -q "missing task" && ! echo "$out" | grep -q "unbound variable" && ok "team without task: clean 'missing task'" || bad "team without task: clean 'missing task'"
out=$("$BIN" team 1:claude "t" --name 2>&1); rc=$?
[[ $rc -eq 1 ]] && echo "$out" | grep -q -- "--name requires a value" && ! echo "$out" | grep -q "unbound variable" && ok "team --name without value: clean error" || bad "team --name without value: clean error"
for sub in fleet debate review; do
    out=$("$BIN" "$sub" p codex --effort 2>&1); rc=$?
    [[ $rc -eq 1 ]] && echo "$out" | grep -q -- "--effort requires a value" && ! echo "$out" | grep -q "unbound variable" && ok "$sub --effort without value: clean error" || bad "$sub --effort without value: clean error"
done
out=$("$BIN" fleet p codex --model 2>&1); rc=$?
[[ $rc -eq 1 ]] && echo "$out" | grep -q -- "--model requires a value" && ok "fleet --model without value: clean error" || bad "fleet --model without value: clean error"

# A10: role names cannot traverse out of roles/.
[[ -f "$ROOT/docs/superpowers/plans/2026-10-04-quintet-tmux-and-roles.md" ]] || bad "role traversal fixture missing"
quintet_role_exists "../docs/superpowers/plans/2026-10-04-quintet-tmux-and-roles" && bad "role traversal rejected" || ok "role traversal rejected"
quintet_role_exists "../docs/x" && bad "role ../docs/x rejected" || ok "role ../docs/x rejected"
[[ -z "$(quintet_role_prompt "../docs/superpowers/plans/2026-10-04-quintet-tmux-and-roles" 2>/dev/null)" ]] && ok "role prompt refuses traversal" || bad "role prompt refuses traversal"
(cd /tmp && unset QUINTET_ROOT && source "$ROOT/lib/roles.sh" && quintet_role_exists implementer) && ok "roles anchored to lib/ without QUINTET_ROOT" || bad "roles anchored to lib/ without QUINTET_ROOT"

# C3: prune --days validation.
mkdir -p "$V/prune/teams/dead-team-v"
for dval in "-1" "abc" "" "1234567"; do
    out=$(QUINTET_STATE_DIR="$V/prune" QUINTET_HOME="$V/home" "$BIN" prune --days "$dval" 2>&1); rc=$?
    [[ $rc -eq 1 ]] && echo "$out" | grep -q -- "--days requires" && ok "prune --days '$dval' rejected" || bad "prune --days '$dval' rejected"
done
out=$(QUINTET_STATE_DIR="$V/prune" QUINTET_HOME="$V/home" "$BIN" prune --days 2>&1); rc=$?
[[ $rc -eq 1 ]] && ! echo "$out" | grep -q "unbound variable" && ok "prune --days without value: clean error" || bad "prune --days without value: clean error"
[[ -d "$V/prune/teams/dead-team-v" ]] && ok "rejected --days deleted nothing" || bad "rejected --days deleted nothing"
out=$(QUINTET_STATE_DIR="$V/prune" QUINTET_HOME="$V/home" "$BIN" prune --days 0012 --dry-run 2>&1); rc=$?
[[ $rc -eq 0 ]] && echo "$out" | grep -q "older than 12 day" && ok "prune --days 0012 is decimal 12" || bad "prune --days 0012 is decimal 12"

# A12 / M1: fleet provider resolution and exit codes (stub CLIs, fake HOME).
fh="$V/fakehome"; sb="$V/stubbin"; mkdir -p "$fh/.codex" "$sb"
printf '#!/bin/sh\necho "stub provider must not run" >&2\nexit 99\n' > "$sb/codex"; chmod +x "$sb/codex"
out=$(env -u OPENAI_API_KEY HOME="$fh" QUINTET_HOME="$fh/.quintet" "$BIN" fleet --no-tmux "hi" codex 2>&1); rc=$?
[[ $rc -eq 1 ]] && echo "$out" | grep -q "no ready providers" && ok "fleet with zero ready providers exits 1" || bad "fleet with zero ready providers exits 1"
out=$(HOME="$fh" QUINTET_HOME="$fh/.quintet" "$BIN" fleet --no-tmux "hi" 1:bogus 2>&1); rc=$?
[[ $rc -eq 1 ]] && echo "$out" | grep -q "unsupported provider" && ok "fleet with unsupported provider exits 1" || bad "fleet with unsupported provider exits 1"
out=$(HOME="$fh" QUINTET_HOME="$fh/.quintet" "$BIN" debate --no-tmux "hi" 1:bogus 2>&1); rc=$?
[[ $rc -eq 1 ]] && ok "debate with unsupported provider exits 1" || bad "debate with unsupported provider exits 1"
touch "$fh/.codex/auth.json"
resolved=$(export PATH="$sb:$PATH" HOME="$fh" QUINTET_HOME="$fh/.quintet"; source "$ROOT/lib/reliability.sh"
    declare -a rp=(); _quintet_resolve_providers rp "1:codex:implementer,codex:reviewer:o3"; echo "${rp[*]}")
[[ "$resolved" == "codex codex" ]] && ok "fleet 1:codex:implementer resolves to codex" || bad "fleet 1:codex:implementer resolves to codex (got '$resolved')"
out=$(PATH="$sb:$PATH" HOME="$fh" QUINTET_HOME="$fh/.quintet" QUINTET_CODEX_ONESHOT_CMD='echo "mock codex answer"' \
    "$BIN" fleet --no-tmux "hi" 1:codex:implementer 2>&1); rc=$?
[[ $rc -eq 0 ]] && echo "$out" | grep -q "mock codex answer" && ok "fleet runs N:provider:role token" || bad "fleet runs N:provider:role token"

unset QUINTET_CLAUDE_LAUNCH QUINTET_CLAUDE_WARMUP QUINTET_STATE_DIR
rm -rf "$V"

echo "── 6. tmux targeting & worker environment ──"
W="$(mktemp -d)"; mkdir -p "$W/home" "$W/tmp" "$W/ftmp"
export QUINTET_STATE_DIR="$W/state" QUINTET_CLAUDE_LAUNCH='bash --norc' QUINTET_CLAUDE_WARMUP=1

# A2: exact session/window targets (no tmux prefix matching).
P1="pfx-$$"; P2="pfx-$$-bar"
"$BIN" team 1:claude:implementer "t" --name "$P2" --skip-auth-check --cwd /tmp >/dev/null 2>&1
ttmux has-session -t "=quintet-$P2" 2>/dev/null && ok "team $P2 started" || bad "team $P2 started"
"$BIN" team status "$P1" >/dev/null 2>&1 && bad "status of prefix name is not running" || ok "status of prefix name is not running"
"$BIN" team send "$P2" "w1-claude" "echo x" >/dev/null 2>&1 && bad "send to worker prefix rejected" || ok "send to worker prefix rejected"
[[ -z "$("$BIN" team capture "$P2" "w1-claude" 2>/dev/null)" ]] && ok "capture of worker prefix is empty" || bad "capture of worker prefix is empty"
"$BIN" team 1:claude "t" --name "$P1" --skip-auth-check --cwd /tmp >/dev/null 2>&1 && ok "prefix-named team starts alongside" || bad "prefix-named team starts alongside"
"$BIN" team shutdown "$P1" --force >/dev/null 2>&1
ttmux has-session -t "=quintet-$P2" 2>/dev/null && ok "shutdown $P1 leaves quintet-$P2" || bad "shutdown $P1 leaves quintet-$P2"
ttmux has-session -t "=quintet-$P1" 2>/dev/null && bad "shutdown $P1 kills quintet-$P1" || ok "shutdown $P1 kills quintet-$P1"
"$BIN" team shutdown "$P2" --force >/dev/null 2>&1

# A4: allowlisted caller env reaches workers even when the tmux server was
# started with an empty environment. Dummy vars only; values are never printed.
ESOCK="${QUINTET_TMUX_SOCKET}-env"
trap 'tmux -L "$QUINTET_TMUX_SOCKET" kill-server >/dev/null 2>&1; tmux -L "$ESOCK" kill-server >/dev/null 2>&1; rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$QUINTET_TMUX_SOCKET" "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$ESOCK"' EXIT
mkdir -p "$W/srvhome"
env -i PATH=/usr/bin:/bin HOME="$W/srvhome" "$(command -v tmux)" -L "$ESOCK" new-session -d -s keepalive -c "$W" sleep 3600
probe="qprobe-$$-val"; emarker="$W/env-marker.txt"
(
    export QUINTET_TMUX_SOCKET="$ESOCK" HOME="$W/home" QUINTET_HOME="$W/home/.quintet" TMPDIR="$W/tmp"
    export QUINTET_TEST_PROBE="$probe" NOT_ALLOWED_PROBE="$probe"
    "$BIN" team 1:claude "t" --name "envt-$$" --skip-auth-check --cwd /tmp >/dev/null 2>&1
    "$BIN" team send "envt-$$" "w1-claude" \
        "echo \"probe=\${QUINTET_TEST_PROBE:+set} other=\${NOT_ALLOWED_PROBE:+set} home=\$([ \"\$HOME\" = \"$W/home\" ] && echo fake)\" > $emarker" >/dev/null 2>&1
)
sleep 1.5
[[ "$(cat "$emarker" 2>/dev/null)" == "probe=set other= home=fake" ]] && ok "team worker gets allowlisted env, not others" || bad "team worker gets allowlisted env, not others (got '$(cat "$emarker" 2>/dev/null)')"
tmux -L "$ESOCK" list-panes -a -F '#{pane_start_command}' 2>/dev/null | grep -q -- "$probe" && bad "env values absent from pane argv" || ok "env values absent from pane argv"
[[ -z "$(find "$W/tmp" -name '*.env' 2>/dev/null)" && -z "$(find "$W/tmp" -maxdepth 1 -name 'quintet-env.*' 2>/dev/null)" ]] && ok "no team env file remains after spawn" || bad "no team env file remains after spawn"
QUINTET_TMUX_SOCKET="$ESOCK" "$BIN" team shutdown "envt-$$" --force >/dev/null 2>&1
fout=$(export QUINTET_TMUX_SOCKET="$ESOCK" HOME="$W/home" QUINTET_HOME="$W/home/.quintet" TMPDIR="$W/ftmp"
    export ANTHROPIC_BASE_URL="http://quintet-probe.invalid" NOT_ALLOWED_PROBE="$probe"
    export QUINTET_CLAUDE_ONESHOT_CMD='echo "base=${ANTHROPIC_BASE_URL:+set} other=${NOT_ALLOWED_PROBE:+set} files=$(ls "$TMPDIR"/quintet-fleet.*/ | tr "\n" " ")"'
    "$BIN" fleet "hi" claude 2>/dev/null)
echo "$fout" | grep -q "base=set other= files=" && ok "fleet tmux worker gets provider allowlist, not others" || bad "fleet tmux worker gets provider allowlist, not others"
flist=$(echo "$fout" | grep "files=")
[[ "$flist" == *prompt.txt* && "$flist" != *.env* && "$flist" != *env.sh* ]] && ok "fleet env file deleted before exec (no env.sh)" || bad "fleet env file deleted before exec (no env.sh)"
tmux -L "$ESOCK" kill-server >/dev/null 2>&1

# A4 / A13: per-provider allowlist and 0600 file in a 0700 dir.
mkdir -m 700 "$W/envd"
( export OPENAI_BASE_URL="http://quintet-probe.invalid" QUINTET_TEST_PROBE="$probe" NOT_ALLOWED_PROBE="$probe"
  quintet_write_worker_env claude "$W/envd/c.env"; quintet_write_worker_env codex "$W/envd/x.env" )
[[ "$(grep -c '^declare -x OPENAI_BASE_URL=' "$W/envd/c.env")" == 0 ]] && ok "codex var not in claude env file" || bad "codex var not in claude env file"
[[ "$(grep -c '^declare -x OPENAI_BASE_URL=' "$W/envd/x.env")" == 1 ]] && ok "codex var in codex env file" || bad "codex var in codex env file"
grep -q '^declare -x NOT_ALLOWED_PROBE=' "$W/envd/c.env" && bad "unlisted var not written" || ok "unlisted var not written"
grep -q '^declare -x QUINTET_TEST_PROBE=' "$W/envd/c.env" && ok "QUINTET_* var written" || bad "QUINTET_* var written"
[[ "$(stat -c %a "$W/envd/c.env")" == 600 ]] && ok "worker env file is 0600" || bad "worker env file is 0600"

# Doctor shows the tmux version.
doc_out=$("$BIN" doctor 2>/dev/null)
echo "$doc_out" | grep -q -E '^tmux .*\(tmux [0-9]' && ok "doctor prints tmux version" || bad "doctor prints tmux version"

unset QUINTET_CLAUDE_LAUNCH QUINTET_CLAUDE_WARMUP QUINTET_STATE_DIR
rm -rf "$W"

echo "── 7. launch-command safety & model resolution ──"
X="$(mktemp -d)"; mkdir -p "$X/home" "$X/bin" "$X/log"
# Stub CLIs: record argv one-per-line, never call a real provider.
for c in claude codex; do
    printf '#!/bin/bash\nprintf "%%s\\n" "$@" > "$QUINTET_TEST_STUBLOG/%s.argv"\n[ -n "$QUINTET_TEST_STUB_FAIL" ] && [ "%s" = codex ] && exit 1\necho "stub %s answer"\n' "$c" "$c" "$c" > "$X/bin/$c"
    chmod +x "$X/bin/$c"
done
argv_has() { grep -A1 -x -- "$2" "$X/log/$1.argv" 2>/dev/null | sed -n 2p | grep -qxF -- "$3"; }

# C1: model/effort values are argv elements, never shell syntax.
eval "la=($(quintet_provider_launch_cmd codex false 'x --yolo' '' true))"
[[ "${la[*]}" == "codex --model x --yolo" && "${#la[@]}" -eq 3 ]] && ok "safe codex: '--yolo' only inside --model value" || bad "safe codex: '--yolo' only inside --model value"
eval "la=($(quintet_provider_launch_cmd claude false 'ok; touch /x' 'high; id' false))"
[[ "${#la[@]}" -eq 7 && "${la[4]}" == "ok; touch /x" && "${la[6]}" == "high; id" ]] && ok "claude model/effort stay single argv elements" || bad "claude model/effort stay single argv elements"
[[ "$(quintet_provider_launch_cmd "opencode")" == "opencode --auto" ]] && ok "launch string has no trailing space" || bad "launch string has no trailing space"
eval "la=($(quintet_provider_launch_cmd copilot false m low false))"
[[ "${la[*]}" == "copilot --allow-all --model m --reasoning-effort low" ]] && ok "copilot: --allow-all + --reasoning-effort (A15/A16)" || bad "copilot: --allow-all + --reasoning-effort (A15/A16)"
agy_err=$(quintet_provider_launch_cmd agy true 2>&1 >/dev/null)
echo "$agy_err" | grep -q "WARN.*agy: --no-mcp not supported" && ok "agy --no-mcp warns (A8)" || bad "agy --no-mcp warns (A8)"
cp_err=$(quintet_provider_launch_cmd copilot true 2>&1 >/dev/null)
echo "$cp_err" | grep -q "WARN.*copilot: --no-mcp is partial" && ok "copilot --no-mcp warns partial (A8)" || bad "copilot --no-mcp warns partial (A8)"

# C7 / decision 3: resolver precedence.
r=$(QUINTET_CODEX_MODEL=env QUINTET_MODEL=glob quintet_resolve_model codex "" spec bare); [[ "$r" == spec ]] && ok "spec model beats env" || bad "spec model beats env"
r=$(QUINTET_CODEX_MODEL=env quintet_resolve_model codex "codex=map" spec bare); [[ "$r" == map ]] && ok "CLI map beats spec" || bad "CLI map beats spec"
r=$(QUINTET_CODEX_MODEL=env quintet_resolve_model codex "" "" bare); [[ "$r" == bare ]] && ok "bare CLI beats env" || bad "bare CLI beats env"
r=$(QUINTET_CODEX_MODEL=env QUINTET_MODEL=glob quintet_resolve_model codex "claude=other" "" ""); [[ "$r" == env ]] && ok "provider env beats global env" || bad "provider env beats global env"
r=$(QUINTET_MODEL=glob quintet_resolve_model codex "" "" ""); [[ "$r" == glob ]] && ok "global env is last resort" || bad "global env is last resort"
r=$(QUINTET_CODEX_EFFORT=env quintet_resolve_effort codex "codex=high" ""); [[ "$r" == high ]] && ok "effort CLI map beats env" || bad "effort CLI map beats env"

# Team: injection, effective model/effort recorded (stub CLIs on PATH, fake HOME).
team_x() { ( export PATH="$X/bin:$PATH" HOME="$X/home" QUINTET_HOME="$X/home/.quintet" QUINTET_STATE_DIR="$X/state" \
    QUINTET_TEST_STUBLOG="$X/log" QUINTET_CLAUDE_WARMUP=1 QUINTET_CODEX_WARMUP=1; "$@" ); }
mj() { cat "$X/state/teams/$1/team.json" 2>/dev/null; }
team_x "$BIN" team 1:claude "t" --name "inj-$$" --skip-auth-check --cwd /tmp --safe --model "ok; touch $X/INJECTED" >/dev/null 2>&1
sleep 1
[[ ! -e "$X/INJECTED" ]] && ok "model 'ok; touch …' not executed (C1)" || bad "model 'ok; touch …' not executed (C1)"
argv_has claude --model "ok; touch $X/INJECTED" && ok "injected model reached claude as one argv value" || bad "injected model reached claude as one argv value"
team_x "$BIN" team shutdown "inj-$$" >/dev/null 2>&1
rm -f "$X/log/"*.argv
team_x env QUINTET_CODEX_MODEL=env "$BIN" team 1:codex:stock:spec "t" --name "spec-$$" --skip-auth-check --cwd /tmp --effort codex=high --no-mcp >/dev/null 2>&1
sleep 1
argv_has codex --model spec && ok "spec model launched over QUINTET_CODEX_MODEL (C7)" || bad "spec model launched over QUINTET_CODEX_MODEL (C7)"
mj "spec-$$" | grep -q '"model": "spec"' && ok "manifest records spec model (C7)" || bad "manifest records spec model (C7)"
mj "spec-$$" | grep -q '"effort": "high"' && ok "manifest records effort (A14)" || bad "manifest records effort (A14)"
mj "spec-$$" | grep -q '"no_mcp_effective": "full"' && ok "manifest records no_mcp_effective (A8)" || bad "manifest records no_mcp_effective (A8)"
team_x "$BIN" team shutdown "spec-$$" >/dev/null 2>&1
team_x env QUINTET_CODEX_MODEL=env "$BIN" team 1:codex "t" --name "envm-$$" --skip-auth-check --cwd /tmp >/dev/null 2>&1
mj "envm-$$" | grep -q '"model": "env"' && ok "env-only model recorded, not default (C7)" || bad "env-only model recorded, not default (C7)"
team_x "$BIN" team shutdown "envm-$$" >/dev/null 2>&1

# A7: fleet --model/--effort per provider; bare value only with one provider.
fleet_x() { ( export PATH="$X/bin:$PATH" HOME="$X/home" QUINTET_HOME="$X/home/.quintet" QUINTET_TEST_STUBLOG="$X/log"
    unset QUINTET_MODEL QUINTET_EFFORT QUINTET_CLAUDE_MODEL QUINTET_CODEX_MODEL QUINTET_CLAUDE_ONESHOT_CMD QUINTET_CODEX_ONESHOT_CMD
    mkdir -p "$X/home/.codex"; touch "$X/home/.codex/auth.json"; "$BIN" "$@" ); }
out=$(fleet_x fleet --no-tmux "hi" claude,codex --model sonnet 2>&1); rc=$?
[[ $rc -eq 1 ]] && echo "$out" | grep -q "bare --model is ambiguous" && ok "fleet bare --model with 2 providers exits 1" || bad "fleet bare --model with 2 providers exits 1"
rm -f "$X/log/"*.argv
QUINTET_TEST_STUB_FAIL=1 fleet_x fleet --no-tmux "hi" codex --model codex=X >/dev/null 2>&1
argv_has codex --model X && ok "fleet --model codex=X reaches codex" || bad "fleet --model codex=X reaches codex"
[[ -f "$X/log/claude.argv" ]] && ! grep -qx -- --model "$X/log/claude.argv" && ok "fallback claude gets no --model" || bad "fallback claude gets no --model"
rm -f "$X/log/"*.argv
QUINTET_TEST_STUB_FAIL=1 fleet_x fleet --no-tmux "hi" codex --model X >/dev/null 2>&1
argv_has codex --model X && [[ -f "$X/log/claude.argv" ]] && ! grep -qx -- --model "$X/log/claude.argv" && ok "bare --model binds to the single provider, not fallback" || bad "bare --model binds to the single provider, not fallback"
rm -f "$X/log/"*.argv
fleet_x fleet "hi" codex --model codex=Y >/dev/null 2>&1
argv_has codex --model Y && ok "fleet tmux worker gets --model codex=Y" || bad "fleet tmux worker gets --model codex=Y"
out=$(fleet_x fleet --no-tmux "hi" codex --model bogus=X 2>&1); rc=$?
[[ $rc -eq 1 ]] && echo "$out" | grep -q "unsupported provider" && ok "fleet --model with unknown provider key exits 1" || bad "fleet --model with unknown provider key exits 1"

rm -rf "$X"

echo "── 8. prune safety ──"
# Everything lives in a sandbox: fake state dir, QUINTET_HOME and HOME. tmux is
# the private test socket (or a missing one for the idle case).
P="$(mktemp -d)"; mkdir -p "$P/state/teams" "$P/home" "$P/stub/nostat" "$P/stub/nostatpy" "$P/nobin"
pr() { ( export QUINTET_STATE_DIR="$P/state" QUINTET_HOME="$P/home" HOME="$P/home"; "$BIN" prune "$@" ); }
# mk_old <dir> — team/debate dir whose dir and files are 10 days old.
mk_old() { mkdir -p "$1"; echo '{}' > "$1/team.json"; touch -d '10 days ago' "$1/team.json" "$1"; }
for s in nostat nostatpy; do printf '#!/bin/sh\nexit 1\n' > "$P/stub/$s/stat"; done
printf '#!/bin/sh\nexit 1\n' > "$P/stub/nostatpy/python3"; chmod +x "$P"/stub/*/*

# M5 / C2: no tmux server is "zero sessions", not an error.
mk_old "$P/state/teams/idle-$$"
out=$(QUINTET_TMUX_SOCKET="quintet-test-$$-idle" pr --days 1 2>&1); rc=$?
[[ $rc -eq 0 && ! -d "$P/state/teams/idle-$$" ]] && ok "prune with no tmux server runs (M5)" || bad "prune with no tmux server runs (M5) (rc=$rc)"
# C2: tmux missing -> die, nothing deleted.
for c in /usr/bin/* /bin/*; do b="${c##*/}"; [[ "$b" == tmux || -e "$P/nobin/$b" ]] || ln -s "$c" "$P/nobin/$b"; done
mk_old "$P/state/teams/notmux-$$"
out=$(PATH="$P/nobin" pr --days 1 2>&1); rc=$?
[[ $rc -eq 1 ]] && echo "$out" | grep -q "tmux unavailable" && [[ -d "$P/state/teams/notmux-$$" ]] && ok "prune without tmux dies, deletes nothing (C2)" || bad "prune without tmux dies, deletes nothing (C2)"
# C2: an inventory error other than "no server" fails closed.
mkdir -p "$P/tt/tmux-$(id -u)"; chmod 000 "$P/tt/tmux-$(id -u)"
out=$(TMUX_TMPDIR="$P/tt" pr --days 1 2>&1); rc=$?
chmod 700 "$P/tt/tmux-$(id -u)"
[[ $rc -eq 1 ]] && echo "$out" | grep -q "cannot read tmux session inventory" && [[ -d "$P/state/teams/notmux-$$" ]] && ok "prune on unreadable tmux socket fails closed (C2)" || bad "prune on unreadable tmux socket fails closed (C2)"
rm -rf "$P/state/teams/notmux-$$"

# Live team is never deleted, even with old state and --days 0.
( export QUINTET_STATE_DIR="$P/state" HOME="$P/home" QUINTET_HOME="$P/home" QUINTET_CLAUDE_LAUNCH='bash --norc' QUINTET_CLAUDE_WARMUP=1
  "$BIN" team 1:claude "t" --name "live-$$" --skip-auth-check --cwd /tmp >/dev/null 2>&1 )
touch -d '10 days ago' "$P/state/teams/live-$$"/* "$P/state/teams/live-$$"
pr --days 0 >/dev/null 2>&1
[[ -d "$P/state/teams/live-$$" ]] && ok "live team state never deleted" || bad "live team state never deleted"
[[ ! -e "$P/state/locks/live-$$.lock" ]] && ok "team start released its lock" || bad "team start released its lock"
out=$( export QUINTET_STATE_DIR="$P/state" HOME="$P/home"; "$BIN" team 1:claude "t" --name "live-$$" --skip-auth-check --cwd /tmp 2>&1 ); rc=$?
[[ $rc -eq 1 && ! -e "$P/state/locks/live-$$.lock" ]] && echo "$out" | grep -q "already running" && ok "die path in team start releases lock" || bad "die path in team start releases lock"
QUINTET_STATE_DIR="$P/state" "$BIN" team shutdown "live-$$" >/dev/null 2>&1

# Locks: a live holder blocks prune and team start; a dead holder's lock is broken.
sleep 60 & live_pid=$!
mk_old "$P/state/teams/lk-$$"; mkdir -p "$P/state/locks/lk-$$.lock"; echo "$live_pid" > "$P/state/locks/lk-$$.lock/pid"
out=$(pr --days 1 2>&1)
[[ -d "$P/state/teams/lk-$$" ]] && echo "$out" | grep -q "skipping 'lk-$$' (locked" && ok "prune skips team locked by a live pid (C2)" || bad "prune skips team locked by a live pid (C2)"
out=$( export QUINTET_STATE_DIR="$P/state" HOME="$P/home" QUINTET_CLAUDE_LAUNCH='bash --norc'; "$BIN" team 1:claude "t" --name "lk-$$" --skip-auth-check --cwd /tmp 2>&1 ); rc=$?
[[ $rc -eq 1 ]] && echo "$out" | grep -q "is locked" && ! ttmux has-session -t "=quintet-lk-$$" 2>/dev/null && ok "team start refuses a locked team (C2)" || bad "team start refuses a locked team (C2)"
kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
( exit 0 ) & dead_pid=$!; wait "$dead_pid"
echo "$dead_pid" > "$P/state/locks/lk-$$.lock/pid"
out=$(pr --days 1 2>&1)
[[ ! -d "$P/state/teams/lk-$$" && ! -e "$P/state/locks/lk-$$.lock" ]] && echo "$out" | grep -q "breaking stale lock" && ok "stale lock (dead pid) broken, team pruned" || bad "stale lock (dead pid) broken, team pruned"
( export QUINTET_STATE_DIR="$P/state"; source "$ROOT/lib/common.sh"
  quintet_lock "both-$$" && ! ( quintet_lock "both-$$" ) ) 2>/dev/null && ok "second quintet_lock on a held lock fails" || bad "second quintet_lock on a held lock fails"
rm -rf "$P/state/locks/both-$$.lock"

# C5: inactivity age = newest file, not dir mtime.
mk_old "$P/state/teams/busy-$$"; echo "[w1] working" > "$P/state/teams/busy-$$/taskboard.md"; touch -d '10 days ago' "$P/state/teams/busy-$$"
pr --days 1 >/dev/null 2>&1
[[ -d "$P/state/teams/busy-$$" ]] && ok "recently touched taskboard keeps old dir (C5)" || bad "recently touched taskboard keeps old dir (C5)"
rm -rf "$P/state/teams/busy-$$"

# C4: unknown timestamps are skipped; python fallback takes the path as argv.
mk_old "$P/state/teams/nots-$$"
out=$(PATH="$P/stub/nostatpy:$PATH" pr --days 1 2>&1)
[[ -d "$P/state/teams/nots-$$" ]] && echo "$out" | grep -q "unknown timestamp" && ok "unstatable team dir skipped (C4)" || bad "unstatable team dir skipped (C4)"
mkdir -p "$P/state/teams/nots-$$/sub"; touch -d '10 days ago' "$P/state/teams/nots-$$/sub" "$P/state/teams/nots-$$"; chmod 000 "$P/state/teams/nots-$$/sub"
out=$(pr --days 1 2>&1)
chmod 700 "$P/state/teams/nots-$$/sub"
[[ -d "$P/state/teams/nots-$$" ]] && echo "$out" | grep -q "unknown timestamp" && ok "unreadable subdir: team skipped (C4)" || bad "unreadable subdir: team skipped (C4)"
rm -rf "$P/state/teams/nots-$$"
apos="$P/it's here"; mkdir -p "$apos"; touch -d '2020-01-02 03:04:05' "$apos"
[[ "$(PATH="$P/stub/nostat:$PATH"; source "$ROOT/lib/prune.sh"; _quintet_mtime_epoch "$apos")" == "$(stat -c %Y "$apos")" ]] && ok "python mtime fallback handles an apostrophe (C4)" || bad "python mtime fallback handles an apostrophe (C4)"
(PATH="$P/stub/nostatpy:$PATH"; source "$ROOT/lib/prune.sh"; _quintet_mtime_epoch "$apos") >/dev/null && bad "mtime helper fails when nothing can stat (C4)" || ok "mtime helper fails when nothing can stat (C4)"

# C9: dry-run counts candidates and deletes nothing; rm failure -> nonzero.
mk_old "$P/state/teams/dry-$$"; mk_old "$P/home/debates/olddeb-$$"
out=$(pr --days 1 --dry-run 2>&1); rc=$?
[[ $rc -eq 0 && -d "$P/state/teams/dry-$$" && -d "$P/home/debates/olddeb-$$" ]] && echo "$out" | grep -q "1 candidate team(s), 1 candidate debate" && ! echo "$out" | grep -q "Prune complete" && ok "dry-run reports candidates, deletes nothing (C9)" || bad "dry-run reports candidates, deletes nothing (C9)"
chmod 555 "$P/state/teams"
out=$(pr --days 1 2>&1); rc=$?
chmod 755 "$P/state/teams"
[[ $rc -eq 1 ]] && echo "$out" | grep -q "failed to remove" && echo "$out" | grep -q "0 dead team(s)" && ok "rm failure -> nonzero exit, not counted (C9)" || bad "rm failure -> nonzero exit, not counted (C9)"
touch -d '10 days ago' "$P/state/teams/dry-$$"
out=$(pr --days 1 --force 2>&1); rc=$?
[[ $rc -eq 0 && ! -d "$P/state/teams/dry-$$" ]] && echo "$out" | grep -q "WARN.*--force is deprecated" && ok "--force warns (deprecated) and prune still works (C9)" || bad "--force warns (deprecated) and prune still works (C9)"

# Decision 2: invalid-named state dirs and QUINTET_HOME/teams are skipped with a WARN.
mk_old "$P/state/teams/a.b"; mk_old "$P/home/teams/hometeam"
out=$(pr --days 1 2>&1)
[[ -d "$P/state/teams/a.b" ]] && echo "$out" | grep -q "skipping 'a.b' (not a valid team name).*rm -rf --" && ok "invalid team dir name skipped with cleanup hint" || bad "invalid team dir name skipped with cleanup hint"
[[ -d "$P/home/teams/hometeam" ]] && echo "$out" | grep -q "skipping $P/home/teams" && ok "QUINTET_HOME/teams skipped with WARN" || bad "QUINTET_HOME/teams skipped with WARN"
out=$( export QUINTET_STATE_DIR="$P/state" HOME="$P/home"; "$BIN" team 1:claude "t" --name "fleet-1-2-3" --skip-auth-check --cwd /tmp 2>&1 ); rc=$?
[[ $rc -eq 1 ]] && echo "$out" | grep -q "reserved for fleet" && ok "team name in fleet namespace rejected" || bad "team name in fleet namespace rejected"

# M3 (plan 4.7): orphaned fleet sessions older than 60 min are swept (test socket only).
now_s=$(date +%s); fold="quintet-fleet-$((now_s - 7200))-1-1"; fnew="quintet-fleet-${now_s}-1-2"
ttmux new-session -d -s "$fold" sleep 600; ttmux new-session -d -s "$fnew" sleep 600
out=$(pr --dry-run 2>&1)
ttmux has-session -t "=$fold" 2>/dev/null && echo "$out" | grep -q "Candidate orphaned fleet session: $fold" && ok "dry-run lists old fleet session, keeps it" || bad "dry-run lists old fleet session, keeps it"
pr >/dev/null 2>&1
! ttmux has-session -t "=$fold" 2>/dev/null && ok "old quintet-fleet-<epoch> session swept (M3)" || bad "old quintet-fleet-<epoch> session swept (M3)"
ttmux has-session -t "=$fnew" 2>/dev/null && ok "fresh fleet session kept" || bad "fresh fleet session kept"
ttmux kill-session -t "=$fnew" 2>/dev/null
[[ -z "$(find "$P/state/locks" -mindepth 1 2>/dev/null)" ]] && ok "no locks left behind" || bad "no locks left behind"
chmod -R u+rwx "$P" 2>/dev/null; rm -rf "$P"

echo
echo "── result: ${PASS} passed, ${FAIL} failed ──"
[[ "$FAIL" -eq 0 ]]
