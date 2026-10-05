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
# Team workers' cwd: kickoff writes inbox files under <cwd>/.quintet, so never /tmp.
QCWD="$(mktemp -d)"
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
[[ "$(quintet_provider_launch_cmd "codex" false "gpt-6.1-sol" "high")" == *"codex --yolo --model gpt-6.1-sol -c model_reasoning_effort=high"* ]] && ok "codex launch with model & effort" || bad "codex launch with model & effort"
[[ "$(quintet_provider_launch_cmd "agy" false "gemini-3.1-pro-high" "high")" == *"agy --dangerously-skip-permissions --model gemini-3.1-pro-high --effort high"* ]] && ok "agy launch with model & effort" || bad "agy launch with model & effort"
[[ "$(quintet_provider_launch_cmd "claude" false "sonnet" "medium")" == *"claude --permission-mode bypassPermissions --model sonnet --effort medium"* ]] && ok "claude launch with model & effort" || bad "claude launch with model & effort"
[[ "$(_quintet_parse_spec "1:codex:implementer:gpt-6.1-sol")" == "codex:implementer:gpt-6.1-sol" ]] && ok "spec parses 1:codex:implementer:gpt-6.1-sol" || bad "spec parses 1:codex:implementer:gpt-6.1-sol"
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
    auth_err=$("$BIN" team 1:qwen "fail task" --name "smoke-auth-fail-$$" --cwd "$QCWD" 2>&1 || true)
    echo "$auth_err" | grep -q "not ready/authenticated" && ok "pre-flight auth rejects unready provider" || bad "pre-flight auth rejects unready provider"
    ttmux has-session -t "quintet-smoke-auth-fail-$$" 2>/dev/null && bad "pre-flight session created on failure" || ok "no session created on auth failure"

    export QUINTET_QWEN_LAUNCH='bash --norc' QUINTET_QWEN_WARMUP=1
    "$BIN" team 1:qwen "skip auth" --name "smoke-auth-skip-$$" --skip-auth-check --cwd "$QCWD" >/dev/null 2>&1 || true
    ttmux has-session -t "quintet-smoke-auth-skip-$$" 2>/dev/null && ok "--skip-auth-check permits start" || bad "--skip-auth-check permits start"
    "$BIN" team shutdown "smoke-auth-skip-$$" --force >/dev/null 2>&1 || true
    unset QUINTET_QWEN_LAUNCH QUINTET_QWEN_WARMUP
    rm -rf "$QUINTET_STATE_DIR"

    QUINTET_STATE_DIR="$(mktemp -d)"
    export QUINTET_CLAUDE_LAUNCH='bash --norc' QUINTET_CLAUDE_WARMUP=2
    T="smoke-$$"
    "$BIN" team 1:claude:implementer,1:claude:stock "smoke" --name "$T" --cwd "$QCWD" --no-mcp --safe >/dev/null 2>&1 && ok "team start" || bad "team start"
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
out=$("$BIN" team 1:claude,1:codex:a:b:c "t" --name "smoke-spec5-$$" --skip-auth-check --cwd "$QCWD" 2>&1); rc=$?
[[ $rc -eq 1 ]] && echo "$out" | grep -q "too many fields" && ok "team spec with 5 fields dies" || bad "team spec with 5 fields dies"
no_sessions "smoke-spec5-$$" && ok "no session after 5-field spec" || bad "no session after 5-field spec"
out=$("$BIN" team 1:claude,1:bogus "t" --name "smoke-bogus-$$" --skip-auth-check --cwd "$QCWD" 2>&1); rc=$?
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
    out=$("$BIN" team 1:claude "t" --name "$bad_name" --skip-auth-check --cwd "$QCWD" 2>&1); rc=$?
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
    declare -a rp=(); _quintet_resolve_providers rp "1:codex:implementer,codex:reviewer:gpt-6.1-sol"; echo "${rp[*]}")
[[ "$resolved" == "codex" ]] && ok "fleet 1:codex:implementer,codex:reviewer resolves to one codex (C-M2)" || bad "fleet 1:codex:implementer,codex:reviewer resolves to one codex (C-M2) (got '$resolved')"
out=$(PATH="$sb:$PATH" HOME="$fh" QUINTET_HOME="$fh/.quintet" QUINTET_CODEX_ONESHOT_CMD='echo "mock codex answer"' \
    "$BIN" fleet --no-tmux "hi" 1:codex:implementer 2>&1); rc=$?
[[ $rc -eq 0 ]] && echo "$out" | grep -q "mock codex answer" && ok "fleet runs N:provider:role token" || bad "fleet runs N:provider:role token"

unset QUINTET_CLAUDE_LAUNCH QUINTET_CLAUDE_WARMUP QUINTET_STATE_DIR
rm -rf "$V"

echo "── 6. tmux targeting & worker environment ──"
W="$(mktemp -d)"; mkdir -p "$W/home/.claude" "$W/tmp" "$W/ftmp"; touch "$W/home/.claude/.credentials.json"
export QUINTET_STATE_DIR="$W/state" QUINTET_CLAUDE_LAUNCH='bash --norc' QUINTET_CLAUDE_WARMUP=1

# A2: exact session/window targets (no tmux prefix matching).
P1="pfx-$$"; P2="pfx-$$-bar"
"$BIN" team 1:claude:implementer "t" --name "$P2" --skip-auth-check --cwd "$QCWD" >/dev/null 2>&1
ttmux has-session -t "=quintet-$P2" 2>/dev/null && ok "team $P2 started" || bad "team $P2 started"
"$BIN" team status "$P1" >/dev/null 2>&1 && bad "status of prefix name is not running" || ok "status of prefix name is not running"
"$BIN" team send "$P2" "w1-claude" "echo x" >/dev/null 2>&1 && bad "send to worker prefix rejected" || ok "send to worker prefix rejected"
[[ -z "$("$BIN" team capture "$P2" "w1-claude" 2>/dev/null)" ]] && ok "capture of worker prefix is empty" || bad "capture of worker prefix is empty"
"$BIN" team 1:claude "t" --name "$P1" --skip-auth-check --cwd "$QCWD" >/dev/null 2>&1 && ok "prefix-named team starts alongside" || bad "prefix-named team starts alongside"
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
    "$BIN" team 1:claude "t" --name "envt-$$" --skip-auth-check --cwd "$QCWD" >/dev/null 2>&1
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
team_x "$BIN" team 1:claude "t" --name "inj-$$" --skip-auth-check --cwd "$QCWD" --safe --model "ok; touch $X/INJECTED" >/dev/null 2>&1; rc=$?
sleep 1
[[ ! -e "$X/INJECTED" ]] && ok "model 'ok; touch …' not executed (C1)" || bad "model 'ok; touch …' not executed (C1)"
# Since S-L4 such a value is rejected up front; argv escaping of odd values is
# covered by the quintet_provider_launch_cmd cases above.
[[ $rc -eq 1 ]] && ! ttmux has-session -t "=quintet-inj-$$" 2>/dev/null && ok "team rejects model 'ok; touch …' before launch (S-L4)" || bad "team rejects model 'ok; touch …' before launch (S-L4)"
team_x "$BIN" team shutdown "inj-$$" >/dev/null 2>&1
rm -f "$X/log/"*.argv
team_x env QUINTET_CODEX_MODEL=env "$BIN" team 1:codex:stock:spec "t" --name "spec-$$" --skip-auth-check --cwd "$QCWD" --effort codex=high --no-mcp >/dev/null 2>&1
sleep 1
argv_has codex --model spec && ok "spec model launched over QUINTET_CODEX_MODEL (C7)" || bad "spec model launched over QUINTET_CODEX_MODEL (C7)"
mj "spec-$$" | grep -q '"model": "spec"' && ok "manifest records spec model (C7)" || bad "manifest records spec model (C7)"
mj "spec-$$" | grep -q '"effort": "high"' && ok "manifest records effort (A14)" || bad "manifest records effort (A14)"
mj "spec-$$" | grep -q '"no_mcp_effective": "full"' && ok "manifest records no_mcp_effective (A8)" || bad "manifest records no_mcp_effective (A8)"
team_x "$BIN" team shutdown "spec-$$" >/dev/null 2>&1
team_x env QUINTET_CODEX_MODEL=env "$BIN" team 1:codex "t" --name "envm-$$" --skip-auth-check --cwd "$QCWD" >/dev/null 2>&1
mj "envm-$$" | grep -q '"model": "env"' && ok "env-only model recorded, not default (C7)" || bad "env-only model recorded, not default (C7)"
team_x "$BIN" team shutdown "envm-$$" >/dev/null 2>&1

# A7: fleet --model/--effort per provider; bare value only with one provider.
fleet_x() { ( export PATH="$X/bin:$PATH" HOME="$X/home" QUINTET_HOME="$X/home/.quintet" QUINTET_TEST_STUBLOG="$X/log"
    unset QUINTET_MODEL QUINTET_EFFORT QUINTET_CLAUDE_MODEL QUINTET_CODEX_MODEL QUINTET_CLAUDE_ONESHOT_CMD QUINTET_CODEX_ONESHOT_CMD
    mkdir -p "$X/home/.codex" "$X/home/.claude"; touch "$X/home/.codex/auth.json" "$X/home/.claude/.credentials.json"; "$BIN" "$@" ); }
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
  "$BIN" team 1:claude "t" --name "live-$$" --skip-auth-check --cwd "$QCWD" >/dev/null 2>&1 )
touch -d '10 days ago' "$P/state/teams/live-$$"/* "$P/state/teams/live-$$"
pr --days 0 >/dev/null 2>&1
[[ -d "$P/state/teams/live-$$" ]] && ok "live team state never deleted" || bad "live team state never deleted"
[[ ! -e "$P/state/locks/live-$$.lock" ]] && ok "team start released its lock" || bad "team start released its lock"
out=$( export QUINTET_STATE_DIR="$P/state" HOME="$P/home"; "$BIN" team 1:claude "t" --name "live-$$" --skip-auth-check --cwd "$QCWD" 2>&1 ); rc=$?
[[ $rc -eq 1 && ! -e "$P/state/locks/live-$$.lock" ]] && echo "$out" | grep -q "already running" && ok "die path in team start releases lock" || bad "die path in team start releases lock"
QUINTET_STATE_DIR="$P/state" "$BIN" team shutdown "live-$$" >/dev/null 2>&1

# Locks: a live holder blocks prune and team start; a dead holder's lock is broken.
sleep 60 & live_pid=$!
mk_old "$P/state/teams/lk-$$"; mkdir -p "$P/state/locks/lk-$$.lock"; echo "$live_pid" > "$P/state/locks/lk-$$.lock/pid"
out=$(pr --days 1 2>&1)
[[ -d "$P/state/teams/lk-$$" ]] && echo "$out" | grep -q "skipping 'lk-$$' (locked" && ok "prune skips team locked by a live pid (C2)" || bad "prune skips team locked by a live pid (C2)"
out=$( export QUINTET_STATE_DIR="$P/state" HOME="$P/home" QUINTET_CLAUDE_LAUNCH='bash --norc'; "$BIN" team 1:claude "t" --name "lk-$$" --skip-auth-check --cwd "$QCWD" 2>&1 ); rc=$?
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
out=$( export QUINTET_STATE_DIR="$P/state" HOME="$P/home"; "$BIN" team 1:claude "t" --name "fleet-1-2-3" --skip-auth-check --cwd "$QCWD" 2>&1 ); rc=$?
[[ $rc -eq 1 ]] && echo "$out" | grep -q "reserved for fleet" && ok "team name in fleet namespace rejected" || bad "team name in fleet namespace rejected"

# M3 (plan 4.7): orphaned fleet sessions older than 60 min (owner pid dead) are swept (test socket only).
( exit 0 ) & fdead=$!; wait "$fdead"
now_s=$(date +%s); fold="quintet-fleet-$((now_s - 7200))-${fdead}-1"; fnew="quintet-fleet-${now_s}-${fdead}-2"
ttmux new-session -d -s "$fold" sleep 600; ttmux new-session -d -s "$fnew" sleep 600
out=$(pr --dry-run 2>&1)
ttmux has-session -t "=$fold" 2>/dev/null && echo "$out" | grep -q "Candidate orphaned fleet session: $fold" && ok "dry-run lists old fleet session, keeps it" || bad "dry-run lists old fleet session, keeps it"
pr >/dev/null 2>&1
! ttmux has-session -t "=$fold" 2>/dev/null && ok "old quintet-fleet-<epoch> session swept (M3)" || bad "old quintet-fleet-<epoch> session swept (M3)"
ttmux has-session -t "=$fnew" 2>/dev/null && ok "fresh fleet session kept" || bad "fresh fleet session kept"
ttmux kill-session -t "=$fnew" 2>/dev/null
[[ -z "$(find "$P/state/locks" -mindepth 1 2>/dev/null)" ]] && ok "no locks left behind" || bad "no locks left behind"
chmod -R u+rwx "$P" 2>/dev/null; rm -rf "$P"

echo "── 9. fleet runtime: cleanup, deadlines, visibility ──"
# Sandbox: fake HOME/QUINTET_HOME/TMPDIR, stub claude+codex, and a PATH with no
# real provider CLIs (they live outside /usr/bin:/bin), so a fallback can't reach one.
F="$(mktemp -d)"; mkdir -p "$F/bin" "$F/home/.codex" "$F/home/.claude" "$F/tmp" "$F/state"; touch "$F/home/.codex/auth.json" "$F/home/.claude/.credentials.json"
printf '#!/bin/bash\n[ -n "$QUINTET_TEST_STUB_FAIL" ] && exit 1\n[ -n "$QUINTET_TEST_SLEEP" ] && sleep "$QUINTET_TEST_SLEEP"\necho "stub codex answer"\n' > "$F/bin/codex"
printf '#!/bin/bash\necho "stub claude answer"\n' > "$F/bin/claude"; chmod +x "$F/bin/"*
ff() { ( export PATH="$F/bin:/usr/bin:/bin" HOME="$F/home" QUINTET_HOME="$F/home/.quintet" TMPDIR="$F/tmp"
    unset QUINTET_CLAUDE_ONESHOT_CMD QUINTET_CODEX_ONESHOT_CMD QUINTET_MODEL QUINTET_EFFORT QUINTET_TIMEOUT QUINTET_CLAUDE_TIMEOUT QUINTET_CODEX_TIMEOUT
    "$@" ); }
fleet_sessions() { ttmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^quintet-fleet-'; }

# M3: SIGINT mid-poll kills the fleet session and removes env files.
( set -m
  ff env QUINTET_CLAUDE_ONESHOT_CMD='sleep 30' "$BIN" fleet "hi" claude >/dev/null 2>&1 &
  bg=$!
  for _ in $(seq 1 40); do fleet_sessions >/dev/null && break; sleep 0.25; done
  sleep 1
  kill -INT -- -"$bg" 2>/dev/null
  wait "$bg" ) 2>/dev/null
for _ in $(seq 1 20); do fleet_sessions >/dev/null || break; sleep 0.25; done
[[ -z "$(fleet_sessions)" ]] && ok "SIGINT mid-poll leaves no quintet-fleet-* session (M3)" || bad "SIGINT mid-poll leaves no quintet-fleet-* session (M3)"
[[ -z "$(find "$F/tmp" -name '*.env' 2>/dev/null)" ]] && ok "SIGINT mid-poll leaves no env file" || bad "SIGINT mid-poll leaves no env file"
[[ -z "$(find "$F/tmp" -mindepth 1 -maxdepth 1 -name 'quintet-fleet.*' 2>/dev/null)" ]] && ok "SIGINT mid-poll leaves no fleet rundir (C-L1)" || bad "SIGINT mid-poll leaves no fleet rundir (C-L1)"
[[ -z "$(find "$F/tmp" -name 'quintet-err*' 2>/dev/null)" ]] && ok "SIGINT mid-poll leaves no one-shot errfile (C-L1)" || bad "SIGINT mid-poll leaves no one-shot errfile (C-L1)"

# A3: SIGINT during a --no-tmux fleet kills the one-shots and leaves no run dir,
# env dir or errfile. The stub runs in its own session and ignores INT, so only
# the fleet's trap (kill the job tree) can stop it. setsid gives the fleet its own
# process group, so the group signal hits it like a terminal's Ctrl-C; perl resets
# the SIGINT disposition that a background child of a non-interactive shell inherits
# as "ignored", which bash can't trap.
# perl records its own pid before exec'ing the fleet: under setsid that pid is the
# fleet's process group. Never derive the group from the stub's parent: once the
# fleet subshell exits, the stub is reparented to `systemd --user`, and signalling
# that group logs the desktop session out (happened twice on 2026-10-05).
a3pidf="$F/a3.pid"; rm -f "$a3pidf"
a3mark="a3-marker-$$-$RANDOM"
ff env A3_PIDF="$a3pidf" setsid perl -e '$SIG{INT}="DEFAULT"; open(my $f, ">", $ENV{A3_PIDF}) or die; print $f $$; close $f; exec @ARGV' env QUINTET_CLAUDE_ONESHOT_CMD='trap "" INT; setsid -w sleep 3171' "$BIN" fleet --no-tmux "$a3mark" claude >/dev/null 2>&1 &
bg=$!
for _ in $(seq 1 40); do pgrep -f "sleep 317[1]" >/dev/null && break; sleep 0.25; done
sleep 1
a3pg="$(cat "$a3pidf" 2>/dev/null)"
# Allowlist: signal the group only if its leader is this test's fleet (its argv
# carries this run's marker), it leads its own group, and it isn't this shell's
# group. A reused pid or any other group fails the check and gets no signal.
if [[ "$a3pg" =~ ^[0-9]+$ && "$a3pg" -gt 1 \
      && "$(ps -o pgid= -p "$a3pg" 2>/dev/null | tr -d ' ')" == "$a3pg" \
      && "$a3pg" != "$(ps -o pgid= -p $$ | tr -d ' ')" ]] \
   && tr '\0' ' ' < "/proc/$a3pg/cmdline" 2>/dev/null | grep -qF -- "$a3mark"; then
  kill -INT -- "-$a3pg" 2>/dev/null
fi
wait "$bg" 2>/dev/null
for _ in $(seq 1 20); do pgrep -f "sleep 317[1]" >/dev/null || break; sleep 0.25; done
pgrep -f "sleep 317[1]" >/dev/null && { pkill -f "sleep 317[1]"; bad "SIGINT in a --no-tmux fleet leaves no stub process (A3)"; } || ok "SIGINT in a --no-tmux fleet leaves no stub process (A3)"
[[ -z "$(find "$F/tmp" -mindepth 1 -name 'quintet-*' 2>/dev/null)" ]] && ok "SIGINT in a --no-tmux fleet leaves no run dir, env dir or errfile (A3)" || bad "SIGINT in a --no-tmux fleet leaves no run dir, env dir or errfile (A3)"

# 1.1: claude gets the prompt on stdin, not in argv.
printf '#!/bin/bash\necho "args=$# argv=$* stdin=$(cat)"\n' > "$F/bin/claude"
out=$(ff env QUINTET_ADVISORY_PREAMBLE= "$BIN" fleet --no-tmux "stdin-marker-11" claude 2>&1)
echo "$out" | grep -q "args=1 argv=-p stdin=stdin-marker-11" && ok "claude one-shot reads the prompt on stdin, not argv (1.1)" || bad "claude one-shot reads the prompt on stdin, not argv (1.1)"
printf '#!/bin/bash\necho "stub claude answer"\n' > "$F/bin/claude"
out=$(ff bash -c 'source "$1/lib/common.sh"; source "$1/lib/providers.sh"; source "$1/lib/reliability.sh"
    quintet_provider_oneshot agy "$(head -c 150000 /dev/zero | tr "\0" x)"; echo "rc=$?"' _ "$ROOT" 2>&1)
echo "$out" | grep -q "prompt too large for agy" && echo "$out" | grep -q "rc=2" && [[ "$(ff bash -c 'source "$1/lib/common.sh"; source "$1/lib/reliability.sh"; classify_error 2 "$2"' _ "$ROOT" "$out")" == permanent ]] \
    && ok "argv provider refuses a 150 KB prompt as a permanent failure (1.1)" || bad "argv provider refuses a 150 KB prompt as a permanent failure (1.1)"

# 1.2: a CLI that ignores TERM is killed at timeout + grace, with nothing left.
t0=$(date +%s)
out=$(ff env QUINTET_CLAUDE_TIMEOUT=1 QUINTET_KILL_GRACE=2 QUINTET_CLAUDE_ONESHOT_CMD='trap "" TERM; sleep 4181' "$BIN" fleet --no-tmux "hi" claude 2>&1)
el=$(( $(date +%s) - t0 ))
[[ $el -lt 8 ]] && echo "$out" | grep -q "claude   \[124:" && ! pgrep -x -f "sleep 4181" >/dev/null && ok "TERM-ignoring CLI killed at timeout+grace, none left (${el}s, 1.2)" || { pkill -x -f "sleep 4181"; bad "TERM-ignoring CLI killed at timeout+grace, none left (${el}s, 1.2)"; }

# 1.3: a leftover child doesn't hold the fleet open; stderr stays out of the answer.
t0=$(date +%s)
out=$(ff env QUINTET_CLAUDE_ONESHOT_CMD='echo warn-noise >&2; echo quick-ans-13; (sleep 4182) & exit 0' "$BIN" fleet "hi" claude 2>/dev/null)
el=$(( $(date +%s) - t0 ))
[[ $el -lt 10 ]] && echo "$out" | grep -q "quick-ans-13" && ! echo "$out" | grep -q "warn-noise" && ! pgrep -x -f "sleep 4182" >/dev/null && ok "leftover child doesn't hold the fleet; stderr not in answer (${el}s, 1.3)" || { pkill -x -f "sleep 4182"; bad "leftover child doesn't hold the fleet; stderr not in answer (${el}s, 1.3)"; }

# 1.4: status codes count only in context; stderr wins over the answer text.
cls_ok=true
while IFS='|' read -r want out err; do
    got="$(bash -c 'source "$1/lib/common.sh"; source "$1/lib/reliability.sh"; classify_error 1 "$2" "$3"' _ "$ROOT" "$out" "$err")"
    [[ "$got" == "$want" ]] || { cls_ok=false; echo "    classify '$out' / '$err': got $got, want $want"; }
done <<'TBL'
transient|Fixed 404 pages and the 500 handler|
transient|We support 401k plans|
transient||HTTP 503 Service Unavailable
transient||Error: 429 Too Many Requests
permanent||error 401: invalid api key
permanent|rate limit|HTTP 403 Forbidden
TBL
$cls_ok && ok "classifier anchors status codes, stderr first (1.4)" || bad "classifier anchors status codes, stderr first (1.4)"

# 3.1: the tmux server going away ends the wait with the seat crashed; a tmux
# error that isn't "gone" (here a fake protocol mismatch) is unknown: no crash.
t0=$(date +%s)
( sleep 3; ttmux kill-server ) &
out=$(ff env QUINTET_TIMEOUT=30 QUINTET_CLAUDE_ONESHOT_CMD='sleep 31' "$BIN" fleet "hi" claude 2>&1)
el=$(( $(date +%s) - t0 )); wait
pkill -x -f 'sleep 31'
[[ $el -lt 15 ]] && echo "$out" | grep -q "claude worker exited without a result" && ok "tmux server gone mid-fleet: seat crashed early (${el}s, 3.1)" || bad "tmux server gone mid-fleet: seat crashed early (${el}s, 3.1)"
mkdir -p "$F/faketmux"
printf '#!/bin/bash\ncase " $* " in *" list-panes "*) echo "protocol version mismatch (client 9, server 8)" >\&2; exit 1 ;; esac\nexec %q "$@"\n' "$(command -v tmux)" > "$F/faketmux/tmux"; chmod +x "$F/faketmux/tmux"
out=$(ff env PATH="$F/faketmux:$F/bin:/usr/bin:/bin" QUINTET_CLAUDE_ONESHOT_CMD='sleep 2; echo unknown-ans-31' "$BIN" fleet "hi" claude 2>&1)
echo "$out" | grep -q "unknown-ans-31" && ! echo "$out" | grep -q "worker-crashed\|exited without a result" && ok "tmux error (unknown liveness) doesn't mark the seat crashed (3.1)" || bad "tmux error (unknown liveness) doesn't mark the seat crashed (3.1)"

# A6: poll deadline follows the slowest provider timeout, not QUINTET_TIMEOUT.
out=$(ff env QUINTET_TIMEOUT=1 QUINTET_CODEX_TIMEOUT=20 QUINTET_TEST_SLEEP=4 "$BIN" fleet "hi" codex 2>&1)
echo "$out" | grep -q "stub codex answer" && echo "$out" | grep -q "codex   \[0:ok\]" && ! echo "$out" | grep -q "124" && ok "QUINTET_CODEX_TIMEOUT > QUINTET_TIMEOUT: no premature 124 (A6)" || bad "QUINTET_CODEX_TIMEOUT > QUINTET_TIMEOUT: no premature 124 (A6)"

# A6 / A5: a worker that dies without a .status is detected early (remain-on-exit).
# The kill only runs inside a tmux pane (its own process group), never in this
# shell's group (workers start under env -i, so TMUX_PANE can't be the guard).
t0=$(date +%s)
smoke_pgid="$(ps -o pgid= -p $$ | tr -d ' ')"
# The CLI runs in its own process group (1.2), so the stub kills its parent's
# group: the pane's worker. Allowlist: the group must be led by a pane on this
# run's test tmux socket (pane pid == pane's pgid). Anything else, including a
# group the stub was reparented into, gets no signal and the test fails.
a6sock="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$QUINTET_TMUX_SOCKET"
a6cmd="pg=\$(ps -o pgid= -p \$PPID | tr -d ' '); [ -n \"\$pg\" ] && [ \"\$pg\" -gt 1 ] && [ \"\$pg\" != $(printf '%q' "$smoke_pgid") ] && $(printf '%q' "$(command -v tmux)") -S $(printf '%q' "$a6sock") list-panes -a -F '#{pane_pid}' 2>/dev/null | grep -qx -- \"\$pg\" && kill -KILL -- -\$pg; exit 1"
out=$(ff env QUINTET_TIMEOUT=20 QUINTET_CLAUDE_ONESHOT_CMD="$a6cmd" "$BIN" fleet "hi" claude 2>&1)
el=$(( $(date +%s) - t0 ))
[[ $el -lt 12 ]] && echo "$out" | grep -q "worker-crashed" && ok "crashed fleet worker detected early (${el}s, A6)" || bad "crashed fleet worker detected early (${el}s, A6)"
echo "$out" | grep -qF "$(quintet_provider_emoji codex) codex (fallback for claude)" && ok "fallback runs after a crashed worker" || bad "fallback runs after a crashed worker"

# A6: a poller timeout feeds the circuit breaker.
rm -rf "$F/home/.quintet/provider-state"
out=$(ff env QUINTET_TIMEOUT=1 QUINTET_CLAUDE_TIMEOUT=1 QUINTET_CLAUDE_ONESHOT_CMD='sleep 60' "$BIN" fleet "hi" claude 2>&1)
echo "$out" | grep -q "claude   \[124:" && grep -q ":124$" "$F/home/.quintet/provider-state/claude.failures" 2>/dev/null && ok "poller timeout -> record_failure (A6)" || bad "poller timeout -> record_failure (A6)"
[[ -z "$(fleet_sessions)" ]] && ok "fleet session killed after polling" || bad "fleet session killed after polling"

# M4: fallback render uses the real provider's label and emoji.
out=$(ff env QUINTET_TEST_STUB_FAIL=1 "$BIN" fleet --no-tmux "hi" codex 2>&1)
echo "$out" | grep -qF "$(quintet_provider_emoji claude) claude (fallback for codex)   [0:ok]" && ok "fallback render shows 'claude (fallback for codex)' (M4)" || bad "fallback render shows 'claude (fallback for codex)' (M4)"
! echo "$out" | grep -q "codex__fallback_claude" && ok "no raw codex__fallback_claude label (M4)" || bad "no raw codex__fallback_claude label (M4)"

# A5: provider stdout is visible in the pane; QUINTET_FLEET_KEEP_SESSION keeps it.
ferr=$(ff env QUINTET_FLEET_KEEP_SESSION=true QUINTET_CLAUDE_ONESHOT_CMD='echo pane-marker-ok' "$BIN" fleet "hi" claude 2>&1 >"$F/fout.txt")
ksess=$(echo "$ferr" | sed -n 's/^Tmux session: tmux attach -t //p' | head -1)
ttmux capture-pane -p -S - -t "=${ksess}:=claude" 2>/dev/null | grep -q "pane-marker-ok" && ok "pane contains the provider's stdout (A5)" || bad "pane contains the provider's stdout (A5)"
[[ "$(ttmux list-panes -t "=${ksess}:=claude" -F '#{pane_dead}' 2>/dev/null)" == 1 ]] && ok "finished fleet window kept (remain-on-exit, A5)" || bad "finished fleet window kept (remain-on-exit, A5)"
grep -q "pane-marker-ok" "$F/fout.txt" && ok "answer still written to .out and rendered" || bad "answer still written to .out and rendered"
echo "$ferr" | grep -q "fleet session kept: tmux attach -t $ksess.*kill-session" && ok "KEEP_SESSION prints attach + kill commands" || bad "KEEP_SESSION prints attach + kill commands"
[[ -n "$ksess" ]] && ttmux kill-session -t "=$ksess" 2>/dev/null

# Plan 5.3 applied to team windows: a CLI that exits at once keeps its pane.
( export PATH="$F/bin:/usr/bin:/bin" HOME="$F/home" QUINTET_HOME="$F/home/.quintet" QUINTET_STATE_DIR="$F/state" TMPDIR="$F/tmp"
  export QUINTET_CLAUDE_LAUNCH='echo fast-exit-marker; exit 3' QUINTET_CLAUDE_WARMUP=0
  "$BIN" team 1:claude "t" --name "fastx-$$" --skip-auth-check --cwd "$QCWD" >/dev/null 2>&1 )
[[ "$(ttmux list-panes -t "=quintet-fastx-$$:=w1-claude" -F '#{pane_dead}' 2>/dev/null)" == 1 ]] \
    && ttmux capture-pane -p -S - -t "=quintet-fastx-$$:=w1-claude" 2>/dev/null | grep -q fast-exit-marker \
    && ok "fast-exiting team worker keeps its pane and output" || bad "fast-exiting team worker keeps its pane and output"
QUINTET_STATE_DIR="$F/state" "$BIN" team shutdown "fastx-$$" --force >/dev/null 2>&1
rm -rf "$F"

echo "── 10. diagnostics, auth heuristics, json fallback ──"
Z="$(mktemp -d)"; mkdir -p "$Z/home" "$Z/stub" "$Z/mac" "$Z/state" "$Z/tmp"
REAL_TMUX="$(command -v tmux)"
# tmux wrapper: can fail pane capture or creation of one named window; otherwise passes through.
printf '#!/bin/bash\ncase " $* " in\n *" capture-pane "*) [ -n "$QUINTET_TEST_FAIL_CAPTURE" ] && exit 1 ;;\n *" new-window "*) [ -n "$QUINTET_TEST_FAIL_WIN" ] && case " $* " in *" -n $QUINTET_TEST_FAIL_WIN "*) exit 1 ;; esac ;;\nesac\nexec "%s" "$@"\n' "$REAL_TMUX" > "$Z/stub/tmux"
printf '#!/bin/sh\necho Darwin\n' > "$Z/mac/uname"; chmod +x "$Z/stub/tmux" "$Z/mac/uname"
zz() { ( export HOME="$Z/home" QUINTET_HOME="$Z/home/.quintet" QUINTET_STATE_DIR="$Z/state" TMPDIR="$Z/tmp"
    export QUINTET_CLAUDE_WARMUP=1 QUINTET_CODEX_WARMUP=1 QUINTET_AGY_WARMUP=1 QUINTET_QWEN_WARMUP=1; "$@" ); }

# C8: modal fixtures. One team, four stub workers, each printing a different screen.
mt="diag-$$"
zz env QUINTET_CLAUDE_LAUNCH='printf "Implemented API key validation\n"; sleep 600' \
       QUINTET_CODEX_LAUNCH='printf "Do you trust this folder? [y/N]\n"; for i in $(seq 25); do echo; done; sleep 600' \
       QUINTET_AGY_LAUNCH='printf "Please log in to continue\n"; sleep 600' \
       QUINTET_QWEN_LAUNCH='printf "Enter your API key: \n"; sleep 600' \
    "$BIN" team 1:claude,1:codex,1:agy,1:qwen "diag" --name "$mt" --skip-auth-check --cwd "$QCWD" >/dev/null 2>&1
sleep 3
dout=$(zz "$BIN" team doctor "$mt" 2>&1); drc=$?
echo "$dout" | grep -q "Worker 'w1-claude': no recognized modal" && ! echo "$dout" | grep -q "w1-claude' is STALLED" && ok "log line 'Implemented API key validation' is not AUTH_REQUIRED (C8)" || bad "log line 'Implemented API key validation' is not AUTH_REQUIRED (C8)"
echo "$dout" | grep -q "Worker 'w2-codex' is STALLED on modal: TRUST_FOLDER" && ok "trust prompt above 25 blank rows detected (C8)" || bad "trust prompt above 25 blank rows detected (C8)"
echo "$dout" | grep -q "Worker 'w3-agy' is STALLED on modal: AUTH_REQUIRED" && ok "anchored 'Please log in' still detected (C8)" || bad "anchored 'Please log in' still detected (C8)"
echo "$dout" | grep -q "Worker 'w4-qwen' is STALLED on modal: AUTH_REQUIRED" && ok "'Enter your API key' prompt detected (C8)" || bad "'Enter your API key' prompt detected (C8)"
! echo "$dout" | grep -q "operational" && ok "doctor no longer says 'operational' (C8)" || bad "doctor no longer says 'operational' (C8)"
[[ $drc -ne 0 ]] && ok "doctor nonzero with stalled workers" || bad "doctor nonzero with stalled workers"

# C8: pane capture failure -> inspection error, nonzero (status 2 from the detector).
dout=$(PATH="$Z/stub:$PATH" QUINTET_TEST_FAIL_CAPTURE=1 zz "$BIN" team doctor "$mt" 2>&1); drc=$?
echo "$dout" | grep -q "inspection error" && [[ $drc -ne 0 ]] && ok "capture failure: doctor reports inspection error, nonzero (C8)" || bad "capture failure: doctor reports inspection error, nonzero (C8)"
! echo "$dout" | grep -q "no recognized modal" && ok "capture failure is not reported as 'no recognized modal' (C8)" || bad "capture failure is not reported as 'no recognized modal' (C8)"
dout=$(PATH="$Z/stub:$PATH" QUINTET_TEST_FAIL_CAPTURE=1 zz "$BIN" team status "$mt" 2>&1)
echo "$dout" | grep -q "INSPECTION_ERROR" && ok "team status flags INSPECTION_ERROR (C8)" || bad "team status flags INSPECTION_ERROR (C8)"
(source "$ROOT/lib/tmux.sh"; source "$ROOT/lib/team.sh"; PATH="$Z/stub:$PATH" QUINTET_TEST_FAIL_CAPTURE=1 _quintet_detect_worker_modal "$mt" w1-claude >/dev/null); [[ $? -eq 2 ]] && ok "detector returns status 2 on capture failure (C8)" || bad "detector returns status 2 on capture failure (C8)"

# C8: manifest vs live windows: one worker window gone, one stray window added.
ttmux kill-window -t "=quintet-$mt:=w4-qwen" 2>/dev/null
ttmux new-window -d -t "=quintet-$mt" -n stray sleep 600 2>/dev/null
dout=$(zz "$BIN" team doctor "$mt" 2>&1); drc=$?
echo "$dout" | grep -q "Worker 'w4-qwen' is in team.json but has no window (missing)" && ok "manifest worker with no window reported (C8)" || bad "manifest worker with no window reported (C8)"
echo "$dout" | grep -q "Window 'stray' is not in team.json (extra)" && ok "window outside the manifest reported (C8)" || bad "window outside the manifest reported (C8)"
zz "$BIN" team shutdown "$mt" --force >/dev/null 2>&1

# A9 / decision 6: auth heuristics with a fake HOME (existence checks only).
ah="$Z/authhome"; mkdir -p "$ah/.claude" "$ah/.gemini"
auth_of() { ( export HOME="$ah"; unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX GEMINI_API_KEY GOOGLE_API_KEY
    for kv in "${@:2}"; do export "$kv"; done
    source "$ROOT/lib/common.sh"; source "$ROOT/lib/providers.sh"; quintet_provider_auth "$1" ); }
[[ "$(auth_of claude)" == none ]] && ok "bare ~/.claude dir, no env: claude auth is none (A9)" || bad "bare ~/.claude dir, no env: claude auth is none (A9)"
[[ "$(auth_of agy)" == none ]] && ok "bare ~/.gemini dir, no env: agy auth is none (A9)" || bad "bare ~/.gemini dir, no env: agy auth is none (A9)"
touch "$ah/.claude/.credentials.json"; [[ "$(auth_of claude)" == oauth ]] && ok "claude .credentials.json -> oauth (A9)" || bad "claude .credentials.json -> oauth (A9)"
rm -f "$ah/.claude/.credentials.json"
[[ "$(auth_of claude ANTHROPIC_API_KEY=dummy)" == api-key ]] && ok "claude ANTHROPIC_API_KEY -> api-key (A9)" || bad "claude ANTHROPIC_API_KEY -> api-key (A9)"
[[ "$(auth_of claude CLAUDE_CODE_OAUTH_TOKEN=dummy)" == api-key ]] && ok "claude CLAUDE_CODE_OAUTH_TOKEN counts as a credential (A9)" || bad "claude CLAUDE_CODE_OAUTH_TOKEN counts as a credential (A9)"
[[ "$(auth_of claude CLAUDE_CODE_USE_BEDROCK=1)" != none ]] && ok "claude Bedrock enabled is not none (A9)" || bad "claude Bedrock enabled is not none (A9)"
[[ "$(auth_of claude CLAUDE_CODE_USE_BEDROCK=0)" == none ]] && ok "claude Bedrock=0 does not count (A9)" || bad "claude Bedrock=0 does not count (A9)"
[[ "$(PATH="$Z/mac:$PATH" auth_of claude)" == unknown ]] && ok "claude on macOS (keychain) is unknown, not none (A9)" || bad "claude on macOS (keychain) is unknown, not none (A9)"
[[ "$(auth_of agy GEMINI_API_KEY=dummy)" == api-key ]] && ok "agy GEMINI_API_KEY -> api-key (A9)" || bad "agy GEMINI_API_KEY -> api-key (A9)"
touch "$ah/.gemini/oauth_creds.json"; [[ "$(auth_of agy)" == oauth ]] && ok "agy oauth_creds.json -> oauth (A9)" || bad "agy oauth_creds.json -> oauth (A9)"
rm -f "$ah/.gemini/oauth_creds.json"; mkdir -p "$ah/.gemini/antigravity-cli"; touch "$ah/.gemini/antigravity-cli/antigravity-oauth-token"
[[ "$(auth_of agy)" == oauth ]] && ok "agy antigravity-oauth-token -> oauth (A9)" || bad "agy antigravity-oauth-token -> oauth (A9)"
rm -f "$ah/.gemini/antigravity-cli/antigravity-oauth-token"
dout=$(PATH="$Z/mac:$PATH" HOME="$ah" "$BIN" doctor 2>/dev/null)
echo "$dout" | grep -E '^.{1,4} claude ' | grep -q "unverified" && ok "doctor shows unknown auth as 'unverified' (A9)" || bad "doctor shows unknown auth as 'unverified' (A9)"
printf '#!/bin/sh\nexit 0\n' > "$Z/stub/claude"; chmod +x "$Z/stub/claude"
out=$(env -u QUINTET_CLAUDE_LAUNCH -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX PATH="$Z/stub:$PATH" HOME="$ah" QUINTET_STATE_DIR="$Z/state" "$BIN" team 1:claude "t" --name "pf-$$" --cwd "$QCWD" 2>&1); rc=$?
[[ $rc -ne 0 ]] && echo "$out" | grep -q "not ready/authenticated" && ok "pre-flight rejects claude with no credentials (A9)" || bad "pre-flight rejects claude with no credentials (A9)"
printf '#!/bin/sh\nexit 0\n' > "$Z/stub/agy"; chmod +x "$Z/stub/agy"
PATH="$Z/stub:$PATH" HOME="$ah" QUINTET_STATE_DIR="$Z/state" QUINTET_GEMINI_LAUNCH='bash --norc' QUINTET_AGY_WARMUP=1 "$BIN" team 1:agy "t" --name "gl-$$" --cwd "$QCWD" >/dev/null 2>&1
ttmux has-session -t "=quintet-gl-$$" 2>/dev/null && ok "pre-flight honors QUINTET_GEMINI_LAUNCH (A9)" || bad "pre-flight honors QUINTET_GEMINI_LAUNCH (A9)"
QUINTET_STATE_DIR="$Z/state" "$BIN" team shutdown "gl-$$" --force >/dev/null 2>&1

# A14: a worker that fails to spawn keeps its index; later workers keep their numbers and subtasks.
sout=$(PATH="$Z/stub:$PATH" QUINTET_TEST_FAIL_WIN=w1-claude zz env QUINTET_CLAUDE_LAUNCH='bash --norc' "$BIN" team 2:claude "shared goal" --name "sf-$$" --skip-auth-check --cwd "$QCWD" --tasks "subtask-one||subtask-two" 2>&1)
sm="$Z/state/teams/sf-$$"
[[ "$(jq -r '.workers[].name' "$sm/team.json" 2>/dev/null)" == "w2-claude" ]] && ok "spawn failure on worker 1: survivor is named w2-claude (A14)" || bad "spawn failure on worker 1: survivor is named w2-claude (A14)"
grep -q 'w2-claude.*subtask-two' "$sm/taskboard.md" && ! grep -q 'subtask-one' "$sm/taskboard.md" && ok "survivor gets subtask 2, not subtask 1 (A14)" || bad "survivor gets subtask 2, not subtask 1 (A14)"
echo "$sout" | grep -q "started with 1 of 2 worker" && ok "final count excludes the failed worker (A14)" || bad "final count excludes the failed worker (A14)"
zz "$BIN" team shutdown "sf-$$" --force >/dev/null 2>&1

# M6: json_escape without jq must produce valid JSON for CR and other C0 controls.
je_ok=true
for t in $'a\rb' $'x\x01y\x1fz\b\f' $'t\tn\n"q"\\'; do
    ( source "$ROOT/lib/common.sh"; have_jq() { return 1; }; json_escape "$t" ) | python3 -m json.tool >/dev/null 2>&1 || je_ok=false
done
$je_ok && ok "json_escape fallback (no jq) emits valid JSON for \\r and C0 controls (M6)" || bad "json_escape fallback (no jq) emits valid JSON for \\r and C0 controls (M6)"
[[ "$( ( source "$ROOT/lib/common.sh"; have_jq() { return 1; }; json_escape $'a\rb' ) | python3 -c 'import sys,json;print(json.load(sys.stdin)=="a\rb")' )" == True ]] && ok "json_escape fallback round-trips \\r (M6)" || bad "json_escape fallback round-trips \\r (M6)"

# Usage text lists the Phase 6 flags.
uo=$("$BIN" help 2>&1); uok=true
for f in --safe --model --effort --no-mcp --tasks --skip-auth-check provider=value --days --dry-run; do echo "$uo" | grep -qF -- "$f" || uok=false; done
$uok && ok "usage lists --safe/--model/--effort/--no-mcp/--tasks/--skip-auth-check/provider=value/prune flags" || bad "usage lists the team/fleet/prune flags"
echo "$uo" | grep -q "deprecated" && ok "usage notes prune --force is deprecated" || bad "usage notes prune --force is deprecated"

# Lint gate: shellcheck -S warning must stay clean (when installed).
if command -v shellcheck >/dev/null 2>&1; then
    [[ -z "$(shellcheck -S warning "$BIN" "$ROOT"/lib/*.sh 2>&1)" ]] && ok "shellcheck -S warning: zero findings" || bad "shellcheck -S warning: zero findings"
fi
rm -rf "$Z"

echo "── 11. state-path symlinks, worker env isolation, locks, values ──"
# Sandbox only: every path below lives under one mktemp parent ($S), HOME is fake,
# PATH has stub CLIs + /usr/bin:/bin (no real provider CLI), tmux uses private sockets.
S="$(mktemp -d)"; mkdir -p "$S/home/.claude" "$S/tmp" "$S/bin" "$S/srvhome"; touch "$S/home/.claude/.credentials.json"
printf '#!/bin/sh\necho "stub $(basename "$0") must not run" >&2\nexit 99\n' > "$S/bin/codex"; cp "$S/bin/codex" "$S/bin/claude"; chmod +x "$S/bin/codex" "$S/bin/claude"
LSOCK="${QUINTET_TMUX_SOCKET}-leak"
trap 'tmux -L "$QUINTET_TMUX_SOCKET" kill-server >/dev/null 2>&1; tmux -L "$ESOCK" kill-server >/dev/null 2>&1; tmux -L "$LSOCK" kill-server >/dev/null 2>&1; rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$QUINTET_TMUX_SOCKET" "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$ESOCK" "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$LSOCK"' EXIT
sx() { ( export PATH="$S/bin:/usr/bin:/bin" HOME="$S/home" QUINTET_HOME="$S/home/.quintet" TMPDIR="$S/tmp"
    unset QUINTET_CLAUDE_ONESHOT_CMD QUINTET_CODEX_ONESHOT_CMD QUINTET_MODEL QUINTET_EFFORT; "$@" ); }

# S-H1: prune never follows a symlinked teams/ (the reported repro), state dir or debates/.
mkdir -p "$S/h1/important-repo" "$S/h1/notes" "$S/h1/evil/.quintet"
echo keep > "$S/h1/important-repo/file"; echo keep > "$S/h1/notes/n"
ln -s ../.. "$S/h1/evil/.quintet/teams"
out=$(cd "$S/h1/evil" && sx env QUINTET_STATE_DIR="$S/h1/evil/.quintet" "$BIN" prune --days 0 2>&1); rc=$?
[[ $rc -ne 0 && -f "$S/h1/important-repo/file" && -f "$S/h1/notes/n" ]] && echo "$out" | grep -q "symlink" && ok "prune refuses symlinked .quintet/teams -> ../.. (S-H1)" || bad "prune refuses symlinked .quintet/teams -> ../.. (S-H1)"
mkdir -p "$S/h1/victimstate/teams/vteam" "$S/h1/s2"; echo keep > "$S/h1/victimstate/teams/vteam/f"; ln -s "$S/h1/victimstate" "$S/h1/s2/.quintet"
out=$(sx env QUINTET_STATE_DIR="$S/h1/s2/.quintet" "$BIN" prune --days 0 2>&1); rc=$?
[[ $rc -ne 0 && -f "$S/h1/victimstate/teams/vteam/f" ]] && ok "prune refuses a symlinked QUINTET_STATE_DIR (S-H1)" || bad "prune refuses a symlinked QUINTET_STATE_DIR (S-H1)"
mkdir -p "$S/h1/victimdeb/d1" "$S/h1/dhome" "$S/h1/dstate"; echo keep > "$S/h1/victimdeb/d1/f"; ln -s "$S/h1/victimdeb" "$S/h1/dhome/debates"
out=$(sx env QUINTET_STATE_DIR="$S/h1/dstate" QUINTET_HOME="$S/h1/dhome" "$BIN" prune --days 0 2>&1); rc=$?
[[ $rc -ne 0 && -f "$S/h1/victimdeb/d1/f" ]] && ok "prune refuses a symlinked debates/ (S-H1)" || bad "prune refuses a symlinked debates/ (S-H1)"
mkdir -p "$S/h1/st3/teams" "$S/h1/victim3"; echo keep > "$S/h1/victim3/f"; ln -s "$S/h1/victim3" "$S/h1/st3/teams/lnk"
out=$(sx env QUINTET_STATE_DIR="$S/h1/st3" "$BIN" prune --days 0 2>&1)
[[ -L "$S/h1/st3/teams/lnk" && -f "$S/h1/victim3/f" ]] && echo "$out" | grep -q "skipping 'lnk' (symlink" && ok "prune skips a symlinked team entry with a WARN (S-H1)" || bad "prune skips a symlinked team entry with a WARN (S-H1)"
mkdir -p "$S/h1/sd/.quintet" "$S/h1/sdtarget/vteam"; echo keep > "$S/h1/sdtarget/vteam/f"; ln -s "$S/h1/sdtarget" "$S/h1/sd/.quintet/teams"
out=$(sx env QUINTET_STATE_DIR="$S/h1/sd/.quintet" "$BIN" team shutdown vteam --force 2>&1); rc=$?
[[ $rc -ne 0 && -f "$S/h1/sdtarget/vteam/f" ]] && echo "$out" | grep -q "symlink" && ok "shutdown --force refuses a symlinked teams/ (S-H1)" || bad "shutdown --force refuses a symlinked teams/ (S-H1)"
mkdir -p "$S/h1/sd2/teams" "$S/h1/t2target"; echo keep > "$S/h1/t2target/f"; ln -s "$S/h1/t2target" "$S/h1/sd2/teams/t2"
out=$(sx env QUINTET_STATE_DIR="$S/h1/sd2" "$BIN" team shutdown t2 --force 2>&1); rc=$?
[[ $rc -ne 0 && -f "$S/h1/t2target/f" ]] && echo "$out" | grep -q "symlink" && ok "shutdown --force refuses a symlinked team dir (S-H1)" || bad "shutdown --force refuses a symlinked team dir (S-H1)"
mkdir -p "$S/h1/b/x" "$S/h1/a"
[[ "$( ( source "$ROOT/lib/common.sh"; quintet_safe_rm_dir "$S/h1/a/../b/x" "$S/h1/a"; echo "rc=$?" ) 2>/dev/null)" == "rc=1" && -d "$S/h1/b/x" ]] && ok "safe rm refuses a dir not directly under the base (S-H1)" || bad "safe rm refuses a dir not directly under the base (S-H1)"

# S-M2: team start never writes through pre-placed state-file symlinks or a symlinked team dir.
mkdir -p "$S/m2/state/teams/smt-$$"; echo original > "$S/m2/victim-board"; echo original > "$S/m2/victim-json"
ln -s "$S/m2/victim-board" "$S/m2/state/teams/smt-$$/taskboard.md"; ln -s "$S/m2/victim-json" "$S/m2/state/teams/smt-$$/team.json"
sx env QUINTET_STATE_DIR="$S/m2/state" QUINTET_CLAUDE_LAUNCH='bash --norc' QUINTET_CLAUDE_WARMUP=0 "$BIN" team 1:claude "t" --name "smt-$$" --skip-auth-check --cwd "$QCWD" >/dev/null 2>&1
[[ "$(cat "$S/m2/victim-board")" == original && "$(cat "$S/m2/victim-json")" == original ]] && ok "team start does not write through taskboard.md/team.json symlinks (S-M2)" || bad "team start does not write through taskboard.md/team.json symlinks (S-M2)"
[[ ! -L "$S/m2/state/teams/smt-$$/taskboard.md" && ! -L "$S/m2/state/teams/smt-$$/team.json" ]] && grep -q "quintet team: smt-$$" "$S/m2/state/teams/smt-$$/taskboard.md" && ok "state files replaced by real files (S-M2)" || bad "state files replaced by real files (S-M2)"
sx env QUINTET_STATE_DIR="$S/m2/state" "$BIN" team shutdown "smt-$$" --force >/dev/null 2>&1
mkdir -p "$S/m2/dtarget"; ln -s "$S/m2/dtarget" "$S/m2/state/teams/smd-$$"
out=$(sx env QUINTET_STATE_DIR="$S/m2/state" QUINTET_CLAUDE_LAUNCH='bash --norc' "$BIN" team 1:claude "t" --name "smd-$$" --skip-auth-check --cwd "$QCWD" 2>&1); rc=$?
[[ $rc -ne 0 && -z "$(ls -A "$S/m2/dtarget")" ]] && echo "$out" | grep -q "symlink" && ! ttmux has-session -t "=quintet-smd-$$" 2>/dev/null && ok "team start refuses a symlinked team dir (S-M2)" || bad "team start refuses a symlinked team dir (S-M2)"
ttmux kill-session -t "=quintet-smd-$$" 2>/dev/null

# S-M1: a tmux server started from a normal shell (not env -i) carries a var in
# its global env; workers must not see it. Dummy values only; never printed.
probe2="qprobe2-$$-val"; lmark="$S/leak-marker.txt"
( export NOT_ALLOWED_PROBE="$probe2" HOME="$S/srvhome"; tmux -L "$LSOCK" new-session -d -s keepalive -c "$S" sleep 3600 )
sx env -u NOT_ALLOWED_PROBE QUINTET_TMUX_SOCKET="$LSOCK" QUINTET_STATE_DIR="$S/m1state" QUINTET_CLAUDE_LAUNCH='bash --norc' QUINTET_CLAUDE_WARMUP=0 \
    LC_PAPER=C "$BIN" team 1:claude "t" --name "leak-$$" --skip-auth-check --cwd "$QCWD" >/dev/null 2>&1
QUINTET_TMUX_SOCKET="$LSOCK" "$BIN" team send "leak-$$" "w1-claude" \
    "echo \"other=\${NOT_ALLOWED_PROBE:+set} lc=\${LC_PAPER:+set} term=\${TERM:+set}\" > $lmark" >/dev/null 2>&1
sleep 1.5
[[ "$(cat "$lmark" 2>/dev/null)" == "other= "* ]] && ok "team worker does not inherit the tmux server's global env (S-M1)" || bad "team worker does not inherit the tmux server's global env (S-M1) (got '$(cut -d' ' -f1 "$lmark" 2>/dev/null)')"
grep -q "lc=set" "$lmark" 2>/dev/null && ok "worker env carries LC_* from the caller (S-M1)" || bad "worker env carries LC_* from the caller (S-M1)"
sx env QUINTET_TMUX_SOCKET="$LSOCK" QUINTET_STATE_DIR="$S/m1state" "$BIN" team shutdown "leak-$$" --force >/dev/null 2>&1
fout=$(sx env -u NOT_ALLOWED_PROBE QUINTET_TMUX_SOCKET="$LSOCK" QUINTET_CLAUDE_ONESHOT_CMD='echo "fleetleak other=${NOT_ALLOWED_PROBE:+set}"' \
    "$BIN" fleet "hi" claude 2>/dev/null)
echo "$fout" | grep -q "fleetleak other=$" && ok "fleet worker does not inherit the tmux server's global env (S-M1)" || bad "fleet worker does not inherit the tmux server's global env (S-M1)"
tmux -L "$LSOCK" kill-server >/dev/null 2>&1

# S-L1: atomic lock with pid; stale/pid-less .break and empty lock dirs don't block forever.
LK="$S/lk"; mkdir -p "$LK/locks"
( exit 0 ) & ldead=$!; wait "$ldead"
lk_try() { ( export QUINTET_STATE_DIR="$LK"; source "$ROOT/lib/common.sh"; quintet_lock "$1" ) 2>/dev/null; }
mkdir -p "$LK/locks/a.lock" "$LK/locks/a.lock.break"; echo "$ldead" > "$LK/locks/a.lock/pid"; echo "$ldead" > "$LK/locks/a.lock.break/pid"
lk_try a && [[ "$(cat "$LK/locks/a.lock/pid")" == "$$" && ! -e "$LK/locks/a.lock.break" ]] && ok "leftover .break with a dead pid is broken (S-L1)" || bad "leftover .break with a dead pid is broken (S-L1)"
mkdir -p "$LK/locks/c.lock" "$LK/locks/c.lock.break"; echo "$ldead" > "$LK/locks/c.lock/pid"
lk_try c && [[ "$(cat "$LK/locks/c.lock/pid")" == "$$" ]] && ok "pid-less leftover .break does not block (S-L1)" || bad "pid-less leftover .break does not block (S-L1)"
mkdir -p "$LK/locks/b.lock"
lk_try b && [[ "$(cat "$LK/locks/b.lock/pid")" == "$$" ]] && ok "empty pid-less lock dir does not block (S-L1)" || bad "empty pid-less lock dir does not block (S-L1)"
sleep 60 & lkreuse=$!
mkdir -p "$LK/locks/e.lock"; echo "$lkreuse" > "$LK/locks/e.lock/pid"; echo "1 not-this-boot" > "$LK/locks/e.lock/owner"
lk_try e && [[ "$(cat "$LK/locks/e.lock/pid")" == "$$" && -s "$LK/locks/e.lock/owner" ]] && ok "lock with a live but reused pid is broken; new lock records its owner (3.2)" || bad "lock with a live but reused pid is broken; new lock records its owner (3.2)"
kill "$lkreuse" 2>/dev/null; wait "$lkreuse" 2>/dev/null
[[ -z "$(find "$LK/locks" -name '*.tmp.*' 2>/dev/null)" ]] && ok "no lock temp dirs left behind (S-L1)" || bad "no lock temp dirs left behind (S-L1)"
sleep 60 & lklive=$!
mkdir -p "$LK/locks/d.lock" "$LK/teams/d"; echo "$lklive" > "$LK/locks/d.lock/pid"; echo '{}' > "$LK/teams/d/team.json"
out=$(sx env QUINTET_STATE_DIR="$LK" QUINTET_CLAUDE_LAUNCH='bash --norc' "$BIN" team 1:claude "t" --name d --skip-auth-check --cwd "$QCWD" 2>&1); rc=$?
[[ $rc -eq 1 ]] && echo "$out" | grep -qF "rm -rf -- $LK/locks/d.lock" && ok "'locked' error prints the manual cleanup path (S-L1)" || bad "'locked' error prints the manual cleanup path (S-L1)"
out=$(sx env QUINTET_STATE_DIR="$LK" "$BIN" prune --days 0 2>&1)
[[ -d "$LK/teams/d" ]] && echo "$out" | grep -qF "rm -rf -- $LK/locks/d.lock" && ok "prune 'locked' WARN prints the manual cleanup path (S-L1)" || bad "prune 'locked' WARN prints the manual cleanup path (S-L1)"
kill "$lklive" 2>/dev/null; wait "$lklive" 2>/dev/null

# R-L3: no rename primitive (no python3, mv without -T) is a clear error, not "locked".
NR="$S/norename"; mkdir -p "$NR"
for f in /usr/bin/* /bin/*; do
    case "${f##*/}" in python3*|mv) continue ;; esac
    [[ -e "$NR/${f##*/}" ]] || ln -s "$f" "$NR/${f##*/}"
done
printf '#!/bin/sh\necho "mv: invalid option -- T" >&2\nexit 1\n' > "$NR/mv"; chmod +x "$NR/mv"
out=$(sx env PATH="$S/bin:$NR" QUINTET_STATE_DIR="$S/nrstate" QUINTET_CLAUDE_LAUNCH='bash --norc' "$BIN" team 1:claude "t" --name "nr-$$" --skip-auth-check --cwd "$QCWD" 2>&1); rc=$?
[[ $rc -eq 1 ]] && echo "$out" | grep -q "needs GNU mv or python3 for locks" && ! echo "$out" | grep -q "is locked" && ! ttmux has-session -t "=quintet-nr-$$" 2>/dev/null && ok "team start without GNU mv or python3: clear lock error (R-L3)" || bad "team start without GNU mv or python3: clear lock error (R-L3)"
mkdir -p "$S/nrstate/teams/nrp-$$"
out=$(sx env PATH="$S/bin:$NR" QUINTET_STATE_DIR="$S/nrstate" "$BIN" prune --days 0 2>&1); rc=$?
[[ $rc -eq 1 && -d "$S/nrstate/teams/nrp-$$" ]] && echo "$out" | grep -q "needs GNU mv or python3 for locks" && ok "prune without GNU mv or python3: clear lock error (R-L3)" || bad "prune without GNU mv or python3: clear lock error (R-L3)"
ttmux kill-session -t "=quintet-nr-$$" 2>/dev/null

# R-L4: 30 concurrent breakers of a stale .break and stale lock: exactly one wins.
# A cat that pauses after reading a pid widens every check-then-act window.
mkdir -p "$S/slowcat"; printf '#!/bin/bash\n/usr/bin/cat "$@"; rc=$?\nsleep 0.0$((RANDOM %% 10))\nexit $rc\n' > "$S/slowcat/cat"; chmod +x "$S/slowcat/cat"
rl4ok=true
for _r in 1 2 3; do
    rm -rf "$LK/locks/r.lock" "$LK/locks/r.lock".* "$LK/go" "$LK/won"
    mkdir -p "$LK/locks/r.lock" "$LK/locks/r.lock.break"; echo "$ldead" > "$LK/locks/r.lock/pid"; echo "$ldead" > "$LK/locks/r.lock.break/pid"
    rpids=()
    for _ in $(seq 1 30); do
        PATH="$S/slowcat:$PATH" QUINTET_STATE_DIR="$LK" bash -c 'source "$1/lib/common.sh"; until [[ -e "$2/go" ]]; do :; done
            quintet_lock r && { echo "$$" >> "$2/won"; sleep 1; }' quintet-racer "$ROOT" "$LK" 2>/dev/null &
        rpids+=( $! )
    done
    sleep 0.5; touch "$LK/go"; wait "${rpids[@]}"
    [[ "$(wc -l < "$LK/won" 2>/dev/null)" -eq 1 ]] || rl4ok=false
done
$rl4ok && ok "30 concurrent breakers of a stale .break: exactly one holds the lock (R-L4)" || bad "30 concurrent breakers of a stale .break: exactly one holds the lock (R-L4) (last round: $(wc -l < "$LK/won" 2>/dev/null) winners)"
[[ -z "$(find "$LK/locks" -name '*.dead.*' 2>/dev/null)" ]] && ok "no *.dead.* lock dirs left behind (R-L4)" || bad "no *.dead.* lock dirs left behind (R-L4)"

# S-L3: a team on another tmux socket is checked there. Socket B = $LSOCK.
out=$(sx env QUINTET_TMUX_SOCKET="$LSOCK" QUINTET_STATE_DIR="$S/xsstate" QUINTET_CLAUDE_LAUNCH='bash --norc' QUINTET_CLAUDE_WARMUP=0 "$BIN" team 1:claude "t" --name "xs-$$" --skip-auth-check --cwd "$QCWD" 2>&1)
[[ "$(jq -r .tmux_socket "$S/xsstate/teams/xs-$$/team.json" 2>/dev/null)" == "$LSOCK" ]] && ok "team start records tmux_socket in team.json (S-L3)" || bad "team start records tmux_socket in team.json (S-L3)"
mkdir -p "$S/xsstate/teams/xn-$$" "$S/xsstate/teams/xd-$$" "$S/xsstate/teams/xi-$$"
printf '{"tmux_socket": "%s"}\n' "$LSOCK" > "$S/xsstate/teams/xn-$$/team.json"
printf '{"tmux_socket": "%s"}\n' "${QUINTET_TMUX_SOCKET}-dead" > "$S/xsstate/teams/xd-$$/team.json"
printf '{"tmux_socket": "../x y"}\n' > "$S/xsstate/teams/xi-$$/team.json"
out=$(sx env QUINTET_STATE_DIR="$S/xsstate" "$BIN" prune --days 0 2>&1)
[[ -d "$S/xsstate/teams/xs-$$" ]] && tmux -L "$LSOCK" has-session -t "=quintet-xs-$$" 2>/dev/null && ok "prune on socket A keeps a team live on socket B (S-L3)" || bad "prune on socket A keeps a team live on socket B (S-L3)"
[[ ! -d "$S/xsstate/teams/xn-$$" ]] && ok "prune removes a team whose session is gone from a live socket B (S-L3)" || bad "prune removes a team whose session is gone from a live socket B (S-L3)"
[[ ! -d "$S/xsstate/teams/xd-$$" ]] && ok "prune removes a team on a dead socket (S-L3)" || bad "prune removes a team on a dead socket (S-L3)"
[[ -d "$S/xsstate/teams/xi-$$" ]] && echo "$out" | grep -q "skipping 'xi-$$' (invalid tmux_socket" && ok "prune skips a team with an invalid tmux_socket, with a WARN (S-L3)" || bad "prune skips a team with an invalid tmux_socket, with a WARN (S-L3)"
tmux -L "$LSOCK" kill-server >/dev/null 2>&1
sx env QUINTET_STATE_DIR="$S/xsstate" "$BIN" prune --days 0 >/dev/null 2>&1
[[ ! -d "$S/xsstate/teams/xs-$$" ]] && ok "prune removes the socket-B team once B is gone (S-L3)" || bad "prune removes the socket-B team once B is gone (S-L3)"

# The validator echoes a rejected value escaped (printf %q) and truncated to 40.
out=$( ( quintet_validate_model_value --model $'-\e[31m'"$(printf 'a%.0s' {1..60})" ) 2>&1 )
[[ "$out" != *$'\e'* && "$out" == *"\$'-\\E[31m"* && "$out" == *"..."* && "$out" != *"$(printf 'a%.0s' {1..40})"* ]] && ok "validator echo is %q-escaped and truncated (S-L4)" || bad "validator echo is %q-escaped and truncated (S-L4) (got: $(printf '%q' "$out"))"

# S-L2: an old fleet session whose owner pid is alive is not swept.
sleep 600 & fown=$!
fl_live="quintet-fleet-$(( $(date +%s) - 7200 ))-${fown}-9"
ttmux new-session -d -s "$fl_live" sleep 600
sx env QUINTET_STATE_DIR="$S/l2state" "$BIN" prune >/dev/null 2>&1
ttmux has-session -t "=$fl_live" 2>/dev/null && ok "old fleet session with a live owner pid kept (S-L2)" || bad "old fleet session with a live owner pid kept (S-L2)"
ttmux kill-session -t "=$fl_live" 2>/dev/null
kill "$fown" 2>/dev/null; wait "$fown" 2>/dev/null

# S-L4: model/effort values that could act as flags are rejected (CLI and spec);
# legitimate names keep working.
out=$(sx env QUINTET_CODEX_ONESHOT_CMD='echo must-not-run' "$BIN" fleet --no-tmux "hi" codex --model "--dangerously-skip-permissions" 2>&1); rc=$?
[[ $rc -eq 1 ]] && echo "$out" | grep -q "invalid value" && ! echo "$out" | grep -q "must-not-run" && ok "fleet --model '--dangerously-…' rejected (S-L4)" || bad "fleet --model '--dangerously-…' rejected (S-L4)"
out=$(sx env QUINTET_STATE_DIR="$S/l4state" QUINTET_CODEX_LAUNCH='bash --norc' "$BIN" team 1:codex "t" --name "l4-$$" --skip-auth-check --cwd "$QCWD" --effort codex=-x 2>&1); rc=$?
[[ $rc -eq 1 ]] && echo "$out" | grep -q "invalid value" && ! ttmux has-session -t "=quintet-l4-$$" 2>/dev/null && ok "team --effort codex=-x rejected (S-L4)" || bad "team --effort codex=-x rejected (S-L4)"
ttmux kill-session -t "=quintet-l4-$$" 2>/dev/null
( _quintet_parse_spec "1:codex:stock:-x" ) >/dev/null 2>&1 && bad "spec model '-x' rejected (S-L4)" || ok "spec model '-x' rejected (S-L4)"
l4ok=true
for mv in ollama:qwen3 gpt-6.1-sol local-model@v2 openrouter/qwen/qwen3-coder gemini-3.8-flash-high 'opus[1m]' 'claude-sonnet-5-5[1m]'; do
    ( m=""; b=""; quintet_parse_cli_value --model "$mv" m b; [[ "$b" == "$mv" ]] ) >/dev/null 2>&1 || l4ok=false
done
( m=""; b=""; quintet_parse_cli_value --model "codex=gpt-6.1-sol,claude=sonnet" m b; [[ "$m" == "codex=gpt-6.1-sol,claude=sonnet" ]] ) >/dev/null 2>&1 || l4ok=false
[[ "$(_quintet_parse_spec "1:codex:stock:gpt-6.1-sol" 2>/dev/null)" == "codex:stock:gpt-6.1-sol" ]] || l4ok=false
$l4ok && ok "legitimate model names (ollama:qwen3, gpt-6.1-sol, …) still accepted (S-L4)" || bad "legitimate model names (ollama:qwen3, gpt-6.1-sol, …) still accepted (S-L4)"
rm -rf "$S"

echo "── 12. worker exit, duplicate providers, empty team, traps, auth heuristics ──"
# Sandbox: fake HOME/TMPDIR/state, stub CLIs on a PATH without real provider CLIs.
C="$(mktemp -d)"; mkdir -p "$C/home/.codex" "$C/home/.claude" "$C/tmp" "$C/state" "$C/bin" "$C/stub"
touch "$C/home/.codex/auth.json" "$C/home/.claude/.credentials.json"
printf '#!/bin/bash\necho "stub codex answer"\n' > "$C/bin/codex"; printf '#!/bin/bash\necho "stub claude answer"\n' > "$C/bin/claude"; chmod +x "$C/bin/"*
printf '#!/bin/bash\ncase " $* " in *" new-window "*) [ -n "$QUINTET_TEST_FAIL_WIN" ] && case " $* " in *" -n $QUINTET_TEST_FAIL_WIN "*) exit 1 ;; esac ;; esac\nexec "%s" "$@"\n' "$(command -v tmux)" > "$C/stub/tmux"; chmod +x "$C/stub/tmux"
cx() { ( export PATH="$C/bin:/usr/bin:/bin" HOME="$C/home" QUINTET_HOME="$C/home/.quintet" QUINTET_STATE_DIR="$C/state" TMPDIR="$C/tmp"
    unset QUINTET_CLAUDE_ONESHOT_CMD QUINTET_CODEX_ONESHOT_CMD QUINTET_MODEL QUINTET_EFFORT QUINTET_MODEL_CLI QUINTET_MODEL_MAP; "$@" ); }

# C-M1: a worker whose CLI exited is reported, and doctor counts it.
cx env QUINTET_CLAUDE_LAUNCH='echo exiting-now; exit 3' QUINTET_CLAUDE_WARMUP=0 "$BIN" team 1:claude "t" --name "ex-$$" --skip-auth-check --cwd "$QCWD" >/dev/null 2>&1
sleep 1
sout=$(cx "$BIN" team status "ex-$$" 2>&1); src=$?
[[ $src -eq 1 ]] && ok "team status returns 1 with an exited worker (A2)" || bad "team status returns 1 with an exited worker (A2) (rc $src)"
echo "$sout" | grep -q "w1-claude.*EXITED (status 3)" && ok "team status reports an exited worker as EXITED (status 3) (C-M1)" || bad "team status reports an exited worker as EXITED (status 3) (C-M1)"
dout=$(cx "$BIN" team doctor "ex-$$" 2>&1); drc=$?
[[ $drc -ne 0 ]] && echo "$dout" | grep -q "Worker 'w1-claude' EXITED (status 3)" && ok "team doctor counts an exited worker as an issue, nonzero (C-M1)" || bad "team doctor counts an exited worker as an issue, nonzero (C-M1)"
cx "$BIN" team shutdown "ex-$$" --force >/dev/null 2>&1

# C-M2: duplicate providers dedupe; a bare --model binds to the one provider.
bound=$( ( export QUINTET_MODEL_CLI=m1; unset QUINTET_MODEL_MAP; _quintet_bind_bare_cli "1:codex:implementer,1:codex:reviewer" codex; echo "${QUINTET_MODEL_MAP:-}" ) 2>/dev/null)
[[ "$bound" == "codex=m1" ]] && ok "bare --model with a duplicated provider binds to it (C-M2)" || bad "bare --model with a duplicated provider binds to it (C-M2)"
out=$(cx "$BIN" fleet "hi" "1:codex:implementer,1:codex:reviewer" 2>&1)
echo "$out" | grep -q "dropping duplicate provider entry '1:codex:reviewer'" && ok "fleet WARNs about the deduped provider entry (A2)" || bad "fleet WARNs about the deduped provider entry (A2)"
[[ "$(echo "$out" | grep -c "codex   \[0:ok\]")" -eq 1 ]] && ! echo "$out" | grep -q "fallback for codex" && ! echo "$out" | grep -q "cannot create tmux window" && ok "tmux fleet with a duplicated provider runs one healthy worker, no fallback (C-M2)" || bad "tmux fleet with a duplicated provider runs one healthy worker, no fallback (C-M2)"

# C-M3: zero started workers -> nonzero, no session, no team dir, no lock.
out=$(cx env PATH="$C/stub:$C/bin:/usr/bin:/bin" QUINTET_TEST_FAIL_WIN=w1-claude QUINTET_CLAUDE_LAUNCH='bash --norc' "$BIN" team 1:claude "t" --name "zero-$$" --skip-auth-check --cwd "$QCWD" 2>&1); rc=$?
[[ $rc -ne 0 ]] && echo "$out" | grep -q "none of the 1 worker(s) started" && ok "team start with zero started workers exits nonzero (C-M3)" || bad "team start with zero started workers exits nonzero (C-M3)"
! ttmux has-session -t "=quintet-zero-$$" 2>/dev/null && [[ ! -e "$C/state/teams/zero-$$" && ! -e "$C/state/locks/zero-$$.lock" ]] && ok "zero-worker start leaves no session, team dir or lock (C-M3)" || bad "zero-worker start leaves no session, team dir or lock (C-M3)"
ttmux kill-session -t "=quintet-zero-$$" 2>/dev/null

# C-L2: a caller's EXIT trap runs once, not again inside the fan-out subshell.
tlog="$C/trap.log"
cx env QUINTET_CLAUDE_ONESHOT_CMD='echo trap-test' bash -c 'source "$1/lib/common.sh"; source "$1/lib/providers.sh"; source "$1/lib/roles.sh"; source "$1/lib/reliability.sh"
    source "$1/lib/tmux.sh"; source "$1/lib/team.sh"; source "$1/lib/fleet.sh"
    trap "echo parent-exit >> \"\$2\"" EXIT; r="$(_quintet_fan_out "hi" claude claude)"; rm -rf -- "$r"' quintet-trap "$ROOT" "$tlog" >/dev/null 2>&1
[[ "$(grep -c parent-exit "$tlog" 2>/dev/null)" == 1 ]] && ok "caller's EXIT trap runs once around a tmux fan-out (C-L2)" || bad "caller's EXIT trap runs once around a tmux fan-out (C-L2) (ran $(grep -c parent-exit "$tlog" 2>/dev/null)x)"

# C-L5: auth detection needs a prompt shape; success messages don't match.
modal_of() { ( mtxt="$1"; source "$ROOT/lib/tmux.sh"; source "$ROOT/lib/team.sh"; quintet_window_capture() { printf '%s\n' "$mtxt"; }; _quintet_detect_worker_modal t w ) 2>/dev/null; }
for neg in "Login successful" "Sign in complete" "Logged in as dev"; do
    [[ -z "$(modal_of "$neg")" ]] && ok "'$neg' is not AUTH_REQUIRED (C-L5)" || bad "'$neg' is not AUTH_REQUIRED (C-L5)"
done
for pos in "Please log in to continue" "Sign in with your browser:" "Login:"; do
    [[ "$(modal_of "$pos")" == AUTH_REQUIRED ]] && ok "'$pos' is AUTH_REQUIRED (C-L5)" || bad "'$pos' is AUTH_REQUIRED (C-L5)"
done
# Phase 0: codex's hook-trust screen is a modal (kickoff holds on it).
[[ "$(modal_of $'  Hooks need review\n  3 hooks are new or changed.\n  Hooks can run outside the sandbox after you trust them.\n\n› 1. Review hooks\n  2. Trust all and continue\n  3. Continue without trusting (hooks won\'t run)\n\n  Press enter to confirm or esc to go back')" == HOOKS_REVIEW ]] \
    && ok "codex 'Hooks need review' screen is HOOKS_REVIEW (P0)" || bad "codex 'Hooks need review' screen is HOOKS_REVIEW (P0)"

# C-L6: the team-runtime skill uses the real worker names for 2:codex,1:agy,1:qwen.
! grep -q 'w2-agy' "$ROOT/skills/quintet-team-runtime/SKILL.md" && grep -q 'team send export-feat w3-agy' "$ROOT/skills/quintet-team-runtime/SKILL.md" && ok "team-runtime skill sends to w3-agy, not w2-agy (C-L6)" || bad "team-runtime skill sends to w3-agy, not w2-agy (C-L6)"

# G-L1: no comment in this file parses as a shellcheck directive (no errors).
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -S error "$ROOT/tests/smoke.sh" >/dev/null 2>&1 && ok "shellcheck -S error tests/smoke.sh: clean (G-L1)" || bad "shellcheck -S error tests/smoke.sh: clean (G-L1)"
fi
rm -rf "$C"

echo "── 13. worker terminal, env allowlist, one-shot env, env values, escaping, kept state ──"
# Sandbox: fake HOME/TMPDIR/state, no real provider CLI on PATH (one-shots use
# QUINTET_<P>_ONESHOT_CMD, team workers a plain bash). Env checks print names or
# set/unset flags only, never values.
N="$(mktemp -d)"; mkdir -p "$N/home/.codex" "$N/home/.claude" "$N/tmp" "$N/state" "$N/bin" "$N/stub" "$N/codexhome" "$N/envd"
touch "$N/home/.codex/auth.json" "$N/home/.claude/.credentials.json"; chmod 700 "$N/envd"
printf '#!/bin/sh\necho "stub $(basename "$0") must not run" >&2\nexit 99\n' > "$N/bin/codex"; cp "$N/bin/codex" "$N/bin/claude"; chmod +x "$N/bin/codex" "$N/bin/claude"
printf '#!/bin/bash\ncase " $* " in *" new-window "*) [ -n "$QUINTET_TEST_FAIL_WIN" ] && case " $* " in *" -n $QUINTET_TEST_FAIL_WIN "*) exit 1 ;; esac ;; esac\ncase " $* " in *" new-session "*) [ -n "$QUINTET_TEST_FAIL_SESSION" ] && exit 1 ;; esac\nexec "%s" "$@"\n' "$(command -v tmux)" > "$N/stub/tmux"; chmod +x "$N/stub/tmux"
nx() { ( export PATH="$N/bin:/usr/bin:/bin" HOME="$N/home" QUINTET_HOME="$N/home/.quintet" QUINTET_STATE_DIR="$N/state" TMPDIR="$N/tmp"
    unset QUINTET_CLAUDE_ONESHOT_CMD QUINTET_CODEX_ONESHOT_CMD QUINTET_MODEL QUINTET_EFFORT QUINTET_MODEL_CLI QUINTET_MODEL_MAP QUINTET_EFFORT_CLI QUINTET_EFFORT_MAP \
        QUINTET_CLAUDE_MODEL QUINTET_CODEX_MODEL QUINTET_CLAUDE_EFFORT QUINTET_CODEX_EFFORT; "$@" ); }

# R-M1: team and fleet tmux workers get tmux's TERM (and TMUX, TMUX_PANE), not the
# caller's, whether the caller's TERM is xterm-kitty or unset.
for tcase in kitty unset; do
    if [[ "$tcase" == kitty ]]; then tset=(env TERM=xterm-kitty); else tset=(env -u TERM); fi
    tm="$N/term-$tcase.txt"
    nx "${tset[@]}" QUINTET_CLAUDE_LAUNCH='bash --norc' QUINTET_CLAUDE_WARMUP=0 "$BIN" team 1:claude "t" --name "term-$tcase-$$" --skip-auth-check --cwd "$QCWD" >/dev/null 2>&1
    dterm="$(ttmux show -gv default-terminal 2>/dev/null)"
    nx "$BIN" team send "term-$tcase-$$" "w1-claude" "echo \"term=\$TERM pane=\${TMUX_PANE:+set} tmux=\${TMUX:+set}\" > $tm" >/dev/null 2>&1
    sleep 1.5
    [[ -n "$dterm" && "$dterm" != xterm-kitty && "$(cat "$tm" 2>/dev/null)" == "term=$dterm pane=set tmux=set" ]] && ok "team worker gets tmux's TERM/TMUX/TMUX_PANE, caller TERM $tcase (R-M1)" || bad "team worker gets tmux's TERM/TMUX/TMUX_PANE, caller TERM $tcase (R-M1)"
    nx "$BIN" team shutdown "term-$tcase-$$" --force >/dev/null 2>&1
    fo=$(nx "${tset[@]}" QUINTET_CLAUDE_ONESHOT_CMD='echo "fterm=$TERM pane=${TMUX_PANE:+set} tmux=${TMUX:+set}"' "$BIN" fleet "hi" claude 2>/dev/null)
    [[ -n "$dterm" ]] && echo "$fo" | grep -qF "fterm=$dterm pane=set tmux=set" && ok "fleet worker gets tmux's TERM/TMUX/TMUX_PANE, caller TERM $tcase (R-M1)" || bad "fleet worker gets tmux's TERM/TMUX/TMUX_PANE, caller TERM $tcase (R-M1)"
done

# R-M2: non-secret config/connectivity vars are allowlisted; XDG_* is narrowed to
# the base dirs + XDG_RUNTIME_DIR.
( export CODEX_HOME=/x SSH_AUTH_SOCK=/x XDG_RUNTIME_DIR=/x XDG_CONFIG_HOME=/x XDG_SESSION_ID=1 NODE_EXTRA_CA_CERTS=/x ALL_PROXY=x EDITOR=x
  quintet_write_worker_env codex "$N/envd/m2.env" ) 2>/dev/null
m2ok=true
for v in CODEX_HOME SSH_AUTH_SOCK XDG_RUNTIME_DIR XDG_CONFIG_HOME NODE_EXTRA_CA_CERTS ALL_PROXY EDITOR; do grep -q "^declare -x $v=" "$N/envd/m2.env" 2>/dev/null || m2ok=false; done
$m2ok && ok "env file carries CODEX_HOME, SSH_AUTH_SOCK, XDG_RUNTIME_DIR, CA/proxy/editor vars (R-M2)" || bad "env file carries CODEX_HOME, SSH_AUTH_SOCK, XDG_RUNTIME_DIR, CA/proxy/editor vars (R-M2)"
grep -q '^declare -x XDG_SESSION_ID=' "$N/envd/m2.env" 2>/dev/null && bad "XDG_SESSION_ID not passed (XDG_* narrowed, R-M2)" || ok "XDG_SESSION_ID not passed (XDG_* narrowed, R-M2)"
grep -q '^declare -x TERM=' "$N/envd/m2.env" 2>/dev/null && bad "TERM not in the caller-env allowlist (R-M1)" || ok "TERM not in the caller-env allowlist (R-M1)"

# A4 (round 3): locale/terminfo/Node/GH host vars reach every worker; the AWS
# Bedrock config vars reach claude only.
( export LANGUAGE=x TERMINFO=/x TERMINFO_DIRS=/x NODE_OPTIONS=x GH_HOST=x \
    AWS_DEFAULT_REGION=x AWS_CONFIG_FILE=/x AWS_SHARED_CREDENTIALS_FILE=/x
  quintet_write_worker_env codex "$N/envd/a4c.env"
  quintet_write_worker_env claude "$N/envd/a4a.env" ) 2>/dev/null
a4ok=true
for v in LANGUAGE TERMINFO TERMINFO_DIRS NODE_OPTIONS GH_HOST; do
    grep -q "^declare -x $v=" "$N/envd/a4c.env" 2>/dev/null || a4ok=false
done
for v in AWS_DEFAULT_REGION AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE; do
    grep -q "^declare -x $v=" "$N/envd/a4a.env" 2>/dev/null || a4ok=false
    grep -q "^declare -x $v=" "$N/envd/a4c.env" 2>/dev/null && a4ok=false
done
$a4ok && ok "env allowlist carries LANGUAGE/TERMINFO*/NODE_OPTIONS/GH_HOST; AWS config vars claude-only (A4)" || bad "env allowlist carries LANGUAGE/TERMINFO*/NODE_OPTIONS/GH_HOST; AWS config vars claude-only (A4)"
fo=$(nx env CODEX_HOME="$N/codexhome" QUINTET_TEST_WANT="$N/codexhome" \
    QUINTET_CODEX_ONESHOT_CMD='[ "$CODEX_HOME" = "$QUINTET_TEST_WANT" ] && echo codexhome=match || echo codexhome=miss' "$BIN" fleet "hi" codex 2>/dev/null)
echo "$fo" | grep -q "codexhome=match" && ok "custom CODEX_HOME reaches a codex worker (R-M2)" || bad "custom CODEX_HOME reaches a codex worker (R-M2)"

# S-M1 remainder: --no-tmux one-shots run under env -i with the same allowlist.
fo=$(nx env NOT_ALLOWED_PROBE=x OPENAI_API_KEY=dummy-not-a-key QUINTET_TEST_PROBE=x \
    QUINTET_CLAUDE_ONESHOT_CMD='echo "nt other=${NOT_ALLOWED_PROBE:+set} foreign=${OPENAI_API_KEY:+set} quintet=${QUINTET_TEST_PROBE:+set}"' "$BIN" fleet --no-tmux "hi" claude 2>/dev/null)
echo "$fo" | grep -q "nt other= foreign= quintet=set" && ok "--no-tmux fleet worker: no unlisted var, no foreign provider key (S-M1)" || bad "--no-tmux fleet worker: no unlisted var, no foreign provider key (S-M1)"
[[ -z "$(find "$N/tmp" -name 'quintet-env1-*' 2>/dev/null)" ]] && ok "one-shot env dir removed (S-M1)" || bad "one-shot env dir removed (S-M1)"

# S-L4 / R-L1: env-sourced model/effort values are validated before any launch.
out=$(nx env QUINTET_CODEX_MODEL=--x QUINTET_CODEX_ONESHOT_CMD='echo must-not-run' "$BIN" fleet --no-tmux "hi" codex 2>&1); rc=$?
[[ $rc -ne 0 ]] && echo "$out" | grep -q "QUINTET_CODEX_MODEL: invalid value" && ! echo "$out" | grep -q "must-not-run" && ok "QUINTET_CODEX_MODEL=--x rejected before launch (R-L1)" || bad "QUINTET_CODEX_MODEL=--x rejected before launch (R-L1)"
out=$(nx env QUINTET_EFFORT=-x QUINTET_CLAUDE_LAUNCH='bash --norc' "$BIN" team 1:claude "t" --name "envx-$$" --skip-auth-check --cwd "$QCWD" 2>&1); rc=$?
[[ $rc -ne 0 ]] && echo "$out" | grep -q "QUINTET_EFFORT: invalid value" && ! ttmux has-session -t "=quintet-envx-$$" 2>/dev/null && [[ ! -e "$N/state/teams/envx-$$" ]] && ok "QUINTET_EFFORT=-x rejected before team launch (R-L1)" || bad "QUINTET_EFFORT=-x rejected before team launch (R-L1)"
ttmux kill-session -t "=quintet-envx-$$" 2>/dev/null
out=$(nx env QUINTET_MODEL_MAP=codex=-y QUINTET_CODEX_ONESHOT_CMD='echo must-not-run' "$BIN" fleet "hi" codex 2>&1); rc=$?
[[ $rc -ne 0 ]] && echo "$out" | grep -q "invalid value" && ! echo "$out" | grep -q "must-not-run" && [[ -z "$(fleet_sessions)" ]] && ok "QUINTET_MODEL_MAP with a dash value rejected before launch (R-L1)" || bad "QUINTET_MODEL_MAP with a dash value rejected before launch (R-L1)"

# R-M3: argv escaping, unit level (the validator would reject these values): run the
# produced launch command against a stub; each value must arrive as one argv element.
mkdir -p "$N/escbin"
printf '#!/bin/bash\nprintf "%%s\\0" "$@" > "%s/esc.argv"\n' "$N" > "$N/escbin/claude"; chmod +x "$N/escbin/claude"
esc_m="a; touch $N/ESC1 \$(touch $N/ESC2) \`touch $N/ESC3\` \"dq\" 'sq' end"
esc_e="high; touch $N/ESC4"
lc="$(quintet_provider_launch_cmd claude false "$esc_m" "$esc_e" true 2>/dev/null)"
( export PATH="$N/escbin:$PATH"; bash -c "$lc" ) >/dev/null 2>&1
ea=(); [[ -f "$N/esc.argv" ]] && mapfile -d '' ea < "$N/esc.argv"
[[ "${#ea[@]}" -eq 4 && "${ea[0]}" == --model && "${ea[1]}" == "$esc_m" && "${ea[2]}" == --effort && "${ea[3]}" == "$esc_e" ]] && ok "metacharacter model/effort reach the CLI as single argv values (R-M3)" || bad "metacharacter model/effort reach the CLI as single argv values (R-M3)"
[[ -z "$(find "$N" -maxdepth 1 -name 'ESC*' 2>/dev/null)" ]] && ok "no command in a model/effort value ran (R-M3)" || bad "no command in a model/effort value ran (R-M3)"

# R-L2: a zero-worker start keeps a pre-existing team dir and its files; only what
# this start wrote is removed (the prior taskboard.md is restored).
KD="$N/state/teams/kept-$$"; mkdir -p "$KD"; echo keep > "$KD/notes.md"; echo prior-board > "$KD/taskboard.md"
out=$(nx env PATH="$N/stub:$N/bin:/usr/bin:/bin" QUINTET_TEST_FAIL_WIN=w1-claude QUINTET_CLAUDE_LAUNCH='bash --norc' "$BIN" team 1:claude "t" --name "kept-$$" --skip-auth-check --cwd "$QCWD" 2>&1); rc=$?
[[ $rc -ne 0 && "$(cat "$KD/notes.md" 2>/dev/null)" == keep && "$(cat "$KD/taskboard.md" 2>/dev/null)" == prior-board && ! -e "$KD/team.json" && -z "$(find "$KD" -name '.taskboard*' 2>/dev/null)" ]] \
    && ok "zero-worker start keeps prior notes.md and taskboard.md (R-L2)" || bad "zero-worker start keeps prior notes.md and taskboard.md (R-L2)"
rm -f "$KD/taskboard.md"
nx env PATH="$N/stub:$N/bin:/usr/bin:/bin" QUINTET_TEST_FAIL_WIN=w1-claude QUINTET_CLAUDE_LAUNCH='bash --norc' "$BIN" team 1:claude "t" --name "kept-$$" --skip-auth-check --cwd "$QCWD" >/dev/null 2>&1
[[ "$(cat "$KD/notes.md" 2>/dev/null)" == keep && ! -e "$KD/taskboard.md" && ! -e "$N/state/locks/kept-$$.lock" ]] && ! ttmux has-session -t "=quintet-kept-$$" 2>/dev/null \
    && ok "zero-worker start removes only the taskboard.md it wrote, no session or lock (R-L2)" || bad "zero-worker start removes only the taskboard.md it wrote, no session or lock (R-L2)"
ttmux kill-session -t "=quintet-kept-$$" 2>/dev/null

# A2: a die after the taskboard backup (tmux session creation fails) puts the
# prior taskboard back, drops the temp files and releases the lock.
echo prior-board2 > "$KD/taskboard.md"
out=$(nx env PATH="$N/stub:$N/bin:/usr/bin:/bin" QUINTET_TEST_FAIL_SESSION=1 QUINTET_CLAUDE_LAUNCH='bash --norc' "$BIN" team 1:claude "t" --name "kept-$$" --skip-auth-check --cwd "$QCWD" 2>&1); rc=$?
[[ $rc -ne 0 && "$(cat "$KD/taskboard.md" 2>/dev/null)" == prior-board2 && "$(cat "$KD/notes.md" 2>/dev/null)" == keep && -z "$(find "$KD" -name '.taskboard*' 2>/dev/null)" && ! -e "$N/state/locks/kept-$$.lock" ]] \
    && ok "a die after the backup restores the prior taskboard and releases the lock (A2)" || bad "a die after the backup restores the prior taskboard and releases the lock (A2)"
out=$(nx env PATH="$N/stub:$N/bin:/usr/bin:/bin" QUINTET_TEST_FAIL_SESSION=1 QUINTET_CLAUDE_LAUNCH='bash --norc' "$BIN" team 1:claude "t" --name "fresh-$$" --skip-auth-check --cwd "$QCWD" 2>&1); rc=$?
[[ $rc -ne 0 && ! -e "$N/state/teams/fresh-$$" && ! -e "$N/state/locks/fresh-$$.lock" ]] \
    && ok "a die after the backup removes a team dir this start created (A2)" || bad "a die after the backup removes a team dir this start created (A2)"
rm -rf "$N"

echo "── 14. kickoff holds on trust dialogs, resume, send refusal ──"
# A stub CLI draws Claude's first-run trust dialog (text as captured from a real
# run) and logs every key it gets: KEY:DOWN / KEY:ENTER / KEY:<c>, then LINE:<text>
# once trusted. Enter on "No, exit" logs EXIT:NO and quits, like the real one.
# Redraws erase the dialog's own lines in place (cursor up + erase line, as Ink
# does), so the answered dialog is not left in the pane's scrollback.
TR="$(mktemp -d)"; mkdir -p "$TR/home" "$TR/state" "$TR/tmp" "$TR/proj"
cat > "$TR/stub.sh" <<'STUB'
log="$1"; sel=no
erase() { printf '\033[1A\033[2K%.0s' $(seq 16); printf '\r'; }
draw() {
    printf ' Accessing workspace:\n\n %s\n\n' "$PWD"
    printf ' Quick safety check: Is this a project you created or one you trust? (Like your\n'
    printf ' own code, a well-known open source project, or work from your team). If not,\n'
    printf ' take a moment to review what'"'"'s in this folder first.\n\n'
    printf ' Claude Code'"'"'ll be able to read, edit, and execute files here.\n\n Security guide\n\n'
    if [[ $sel == no ]]; then printf ' ❯ No, exit\n   Yes, I trust this folder\n'
    else printf '   No, exit\n ❯ Yes, I trust this folder\n'; fi
    printf '\n Enter to confirm · Esc to cancel\n'
}
draw
while IFS= read -rsn1 k; do
    case "$k" in
        $'\e') read -rsn2 r; if [[ $r == '[B' ]]; then echo KEY:DOWN >> "$log"; sel=yes; erase; draw; else echo "KEY:ESC$r" >> "$log"; fi ;;
        '') echo KEY:ENTER >> "$log"; [[ $sel == yes ]] && break; echo EXIT:NO >> "$log"; exit 1 ;;
        *) echo "KEY:$k" >> "$log" ;;
    esac
done
erase; printf '> ready\n'
while IFS= read -r line; do echo "LINE:$line" >> "$log"; done
STUB
tx() { ( export HOME="$TR/home" QUINTET_HOME="$TR/home/.quintet" QUINTET_STATE_DIR="$TR/state" TMPDIR="$TR/tmp" QUINTET_CLAUDE_WARMUP=1 QUINTET_CODEX_WARMUP=1
    "$@" ); }

# No flag: the task is held; the stub never gets a key.
out=$(tx env QUINTET_CLAUDE_LAUNCH="bash $TR/stub.sh $TR/k1.log" "$BIN" team 1:claude "trust task one" --name "tr1-$$" --skip-auth-check --cwd "$TR/proj" 2>&1)
hf="$TR/state/teams/tr1-$$/held/w1-claude.txt"
echo "$out" | grep -q "w1-claude HELD: TRUST_FOLDER" && echo "$out" | grep -qF "quintet team resume tr1-$$ w1-claude" && echo "$out" | grep -q "tmux attach -t quintet-tr1-$$" \
    && ok "trust dialog at kickoff: WARN names HELD, attach and resume (A1)" || bad "trust dialog at kickoff: WARN names HELD, attach and resume (A1)"
[[ ! -s "$TR/k1.log" ]] && ok "held worker received no key, no Enter (A1)" || bad "held worker received no key, no Enter (A1) (got: $(tr '\n' ' ' < "$TR/k1.log"))"
[[ -f "$hf" && "$(stat -c %a "$hf")" == 600 && "$(stat -c %a "${hf%/*}")" == 700 ]] && grep -q "trust task one" "$(sed -n 's/^Read and follow \(.*\) now\.$/\1/p' "$hf")" && ok "held task saved 0600 in a 0700 dir (A1)" || bad "held task saved 0600 in a 0700 dir (A1)"
grep -qF "[quintet] w1-claude HELD: TRUST_FOLDER" "$TR/state/teams/tr1-$$/taskboard.md" && ok "taskboard notes the held worker (A1)" || bad "taskboard notes the held worker (A1)"
out=$(tx "$BIN" team status "tr1-$$" 2>&1)
echo "$out" | grep -q "STALLED_MODAL: TRUST_FOLDER" && ok "status: current trust dialog is STALLED_MODAL: TRUST_FOLDER (A1)" || bad "status: current trust dialog is STALLED_MODAL: TRUST_FOLDER (A1)"
out=$(tx "$BIN" team send "tr1-$$" w1-claude "hello" 2>&1); rc=$?
[[ $rc -eq 1 && ! -s "$TR/k1.log" ]] && echo "$out" | grep -q "shows a modal (TRUST_FOLDER)" && ok "team send refuses on a modal, no key sent (A1)" || bad "team send refuses on a modal, no key sent (A1)"
out=$(tx "$BIN" team resume "tr1-$$" w1-claude 2>&1); rc=$?
[[ $rc -ne 0 && -f "$hf" && ! -s "$TR/k1.log" ]] && echo "$out" | grep -q "still shows a modal (TRUST_FOLDER)" && ok "resume refuses while the dialog is up (A1)" || bad "resume refuses while the dialog is up (A1)"
tx "$BIN" team resume "tr1-$$" ../x >/dev/null 2>&1 && bad "resume rejects worker '../x' (A1)" || ok "resume rejects worker '../x' (A1)"
ttmux send-keys -t "=quintet-tr1-$$:=w1-claude" Down; sleep 0.5; ttmux send-keys -t "=quintet-tr1-$$:=w1-claude" Enter; sleep 1
out=$(tx "$BIN" team resume "tr1-$$" 2>&1); rc=$?; sleep 1
[[ $rc -eq 0 && ! -e "$hf" ]] && grep -q "^LINE:Read and follow .*/w1-claude\.md now\." "$TR/k1.log" && ok "resume (all held) sends the task once the dialog is answered (A1)" || bad "resume (all held) sends the task once the dialog is answered (A1)"
tx "$BIN" team shutdown "tr1-$$" --force >/dev/null 2>&1

# Old wording is still detected; --force sends anyway.
tx env QUINTET_CLAUDE_LAUNCH='bash --norc' "$BIN" team 1:claude "t" --name "tr4-$$" --skip-auth-check --cwd "$QCWD" >/dev/null 2>&1
tx "$BIN" team send "tr4-$$" w1-claude "printf 'Do you trust this folder? [y/N]: '" >/dev/null 2>&1; sleep 1
out=$(tx "$BIN" team status "tr4-$$" 2>&1)
echo "$out" | grep -q "STALLED_MODAL: TRUST_FOLDER" && ok "old 'Do you trust this folder?' wording still detected (A1)" || bad "old 'Do you trust this folder?' wording still detected (A1)"
tx "$BIN" team send "tr4-$$" w1-claude "echo forced > $TR/forced" >/dev/null 2>&1 && bad "send without --force refused on old wording (A1)" || ok "send without --force refused on old wording (A1)"
tx "$BIN" team send "tr4-$$" w1-claude "echo forced > $TR/forced" --force >/dev/null 2>&1; sleep 1
[[ "$(cat "$TR/forced" 2>/dev/null)" == forced ]] && ok "send --force types through a modal (A1)" || bad "send --force types through a modal (A1)"
tx "$BIN" team shutdown "tr4-$$" --force >/dev/null 2>&1

rm -rf "$TR"

echo "── 15. tmux -c start directories are not format-expanded ──"
# tmux format-expands -c, so an unescaped dir "m#(touch …)n" runs the touch (A1b).
# Own socket, started from inside the sandbox, so a stray #() job would land there.
H="$(mktemp -d)"; mkdir -p "$H/home/.claude" "$H/tmp" "$H/bin" "$H/srv"; touch "$H/home/.claude/.credentials.json"
printf '#!/bin/sh\nexit 99\n' > "$H/bin/claude"; chmod +x "$H/bin/claude"
HSOCK="${QUINTET_TMUX_SOCKET}-hash"; hmark="qpwned$$"
trap 'tmux -L "$QUINTET_TMUX_SOCKET" kill-server >/dev/null 2>&1; tmux -L "$ESOCK" kill-server >/dev/null 2>&1; tmux -L "$LSOCK" kill-server >/dev/null 2>&1; tmux -L "$HSOCK" kill-server >/dev/null 2>&1; rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$QUINTET_TMUX_SOCKET" "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$ESOCK" "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$LSOCK" "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$HSOCK"' EXIT
hx() { ( cd "$H/srv" && export PATH="$H/bin:/usr/bin:/bin" HOME="$H/home" QUINTET_HOME="$H/home/.quintet" QUINTET_STATE_DIR="$H/state" TMPDIR="$H/tmp" QUINTET_TMUX_SOCKET="$HSOCK"
    unset QUINTET_CLAUDE_ONESHOT_CMD QUINTET_MODEL QUINTET_EFFORT; "$@" ); }
hdir="$H/m#(touch $hmark)n #{session_name} x##y tr#"; mkdir -p "$hdir"
hpwned() { find "$H" "$HOME" "$ROOT" "$PWD" / -maxdepth 1 -name "$hmark" 2>/dev/null | grep -q . || find "$H" -name "$hmark" 2>/dev/null | grep -q .; }
hx env QUINTET_CLAUDE_LAUNCH='bash --norc' QUINTET_CLAUDE_WARMUP=0 "$BIN" team 1:claude "t" --name "hash-$$" --skip-auth-check --cwd "$hdir" >/dev/null 2>&1
sleep 1
lp="$(tmux -L "$HSOCK" list-panes -t "=quintet-hash-$$:=leader" -F '#{pane_current_path}' 2>/dev/null)"
wp="$(tmux -L "$HSOCK" list-panes -t "=quintet-hash-$$:=w1-claude" -F '#{pane_current_path}' 2>/dev/null)"
[[ "$lp" == "$hdir" && "$wp" == "$hdir" ]] && ok "team --cwd with '#(…)', '#{…}', '##', trailing '#': leader and worker cwd is the literal dir (A1b)" || bad "team --cwd with '#' chars: literal pane cwd (A1b) (got '$lp' / '$wp')"
hx "$BIN" team shutdown "hash-$$" --force >/dev/null 2>&1
fout=$(cd "$hdir" && hx env QUINTET_CLAUDE_ONESHOT_CMD='echo "fcwd=$PWD"' bash -c 'cd "$1" && "$2" fleet hi claude' _ "$hdir" "$BIN" 2>&1)
echo "$fout" | grep -q "Tmux session:" && echo "$fout" | grep -qxF "fcwd=$hdir" && ok "fleet from a '#(…)' \$PWD: tmux worker runs in the literal dir (A1b)" || bad "fleet from a '#(…)' \$PWD: tmux worker runs in the literal dir (A1b)"
! hpwned && ok "no '#(…)' in a start dir ran (A1b)" || bad "no '#(…)' in a start dir ran (A1b)"
mkdir -p "$H/s#[fg=red]t"
out=$(hx "$BIN" team 1:claude "t" --name "hst-$$" --skip-auth-check --cwd "$H/s#[fg=red]t" 2>&1); rc=$?
[[ $rc -ne 0 ]] && echo "$out" | grep -qF "contains '#['" && ! tmux -L "$HSOCK" has-session -t "=quintet-hst-$$" 2>/dev/null && ok "team --cwd containing '#[' is refused before any session (A1b)" || bad "team --cwd containing '#[' is refused before any session (A1b)"
tmux -L "$HSOCK" kill-server >/dev/null 2>&1
rm -rf "$H"

echo "── 2. typing into team workers ──"
# A stand-in worker: logs each line it reads. swallow: the first Enter leaves the
# text on the input line (as if not submitted). newline: the first Enter becomes a
# newline in a wrapped input box (seen with real claude at startup). busy: shows a
# running-turn footer.
Q2="$(mktemp -d)"; mkdir -p "$Q2/repo" "$Q2/state"; git -C "$Q2/repo" init -q
q2stub() {  # q2stub <mode> -> path of a stub script logging to $Q2/<mode>.log
    local f="$Q2/stub-$1.sh"
    cat > "$f" <<STUB
#!/bin/bash
n=0
[ "$1" = busy ] && printf '• Working (2s • esc to interrupt)\n'
printf '❯ '
while IFS= read -r line; do
  n=\$((n+1)); printf '%s\n' "\$line" >> "$Q2/$1.log"
  if [ "$1" = swallow ] && [ \$n = 1 ]; then printf '❯ %s' "\$line"; continue; fi
  if [ "$1" = newline ] && [ \$n = 1 ]; then printf '❯ %s\n  ' "\$(printf '%s' "\$line" | fold -w 30 | sed '2,\$s/^/  /')"; continue; fi
  [ "$1" = busy ] && printf '• Working (2s • esc to interrupt)\n'
  printf '❯ '
done
STUB
    echo "$f"
}
q2() { ( export QUINTET_STATE_DIR="$Q2/state" QUINTET_CLAUDE_WARMUP=1 QUINTET_SUBMIT_CHECK_DELAY=0.5; "$@" ); }

# 2.1: an Enter that didn't submit is pressed again, once; the text isn't retyped.
q2 env QUINTET_CLAUDE_LAUNCH="bash --norc $(q2stub swallow)" "$BIN" team 1:claude "t" --name "sw-$$" --skip-auth-check --cwd "$Q2/repo" >/dev/null 2>&1
[[ "$(wc -l < "$Q2/swallow.log" 2>/dev/null)" == 2 && -z "$(sed -n 2p "$Q2/swallow.log")" ]] \
    && ok "swallowed first Enter: exactly one more Enter, no retype (2.1)" || bad "swallowed first Enter: exactly one more Enter, no retype (2.1) (log: $(tr '\n' '|' < "$Q2/swallow.log" 2>/dev/null))"
q2 "$BIN" team shutdown "sw-$$" --force >/dev/null 2>&1
q2 env QUINTET_CLAUDE_LAUNCH="bash --norc $(q2stub newline)" "$BIN" team 1:claude "t" --name "nl-$$" --skip-auth-check --cwd "$Q2/repo" >/dev/null 2>&1
[[ "$(wc -l < "$Q2/newline.log" 2>/dev/null)" == 2 && -z "$(sed -n 2p "$Q2/newline.log")" ]] \
    && ok "Enter landed as a newline in a wrapped input: one more Enter (2.1)" || bad "Enter landed as a newline in a wrapped input: one more Enter (2.1) (log: $(tr '\n' '|' < "$Q2/newline.log" 2>/dev/null))"
q2 "$BIN" team shutdown "nl-$$" --force >/dev/null 2>&1

# 2.2: the kickoff is one nudge line; the task is in a 0600 inbox file excluded from git.
q2 env QUINTET_CLAUDE_LAUNCH="bash --norc $(q2stub plain)" "$BIN" team 1:claude "goal-22" --name "ib-$$" --skip-auth-check --cwd "$Q2/repo" >/dev/null 2>&1
ibf="$Q2/repo/.quintet/inbox/ib-$$/w1-claude.md"
[[ "$(wc -l < "$Q2/plain.log" 2>/dev/null)" == 1 ]] && grep -qxF "Read and follow $ibf now." "$Q2/plain.log" \
    && [[ "$(stat -c %a "$ibf" 2>/dev/null)" == 600 ]] && grep -q "goal-22" "$ibf" && grep -qxF '.quintet/' "$Q2/repo/.git/info/exclude" \
    && ok "kickoff: one nudge line, task in a 0600 inbox file, .quintet/ excluded (2.2)" || bad "kickoff: one nudge line, task in a 0600 inbox file, .quintet/ excluded (2.2)"
q2 "$BIN" team send "ib-$$" w1-claude $'line one\nline two' >/dev/null 2>&1; sleep 1
sed -n 2p "$Q2/plain.log" 2>/dev/null | grep -qE "^Read and follow $Q2/repo/\.quintet/inbox/ib-$$/w1-claude-[0-9]+-[0-9]+\.md now\.$" \
    && ok "multi-line team send goes through an inbox file (2.2)" || bad "multi-line team send goes through an inbox file (2.2)"
q2 "$BIN" team shutdown "ib-$$" --force >/dev/null 2>&1

# 2.3: send refuses a busy pane; --busy-ok types.
q2 env QUINTET_CLAUDE_LAUNCH="bash --norc $(q2stub busy)" "$BIN" team 1:claude "t" --name "bz-$$" --skip-auth-check --cwd "$Q2/repo" >/dev/null 2>&1
out=$(q2 "$BIN" team send "bz-$$" w1-claude "busy-marker-23a" 2>&1); rc=$?
[[ $rc -ne 0 ]] && echo "$out" | grep -q "mid-turn" && ! grep -q "busy-marker-23a" "$Q2/busy.log" 2>/dev/null \
    && ok "team send refuses a busy pane (2.3)" || bad "team send refuses a busy pane (2.3)"
q2 "$BIN" team send "bz-$$" w1-claude "busy-marker-23b" --busy-ok >/dev/null 2>&1; sleep 1
grep -qx "busy-marker-23b" "$Q2/busy.log" 2>/dev/null && ok "--busy-ok types into a busy pane (2.3)" || bad "--busy-ok types into a busy pane (2.3)"
q2 "$BIN" team shutdown "bz-$$" --force >/dev/null 2>&1
rm -rf "$Q2"

rm -rf "$QCWD"

echo
echo "── result: ${PASS} passed, ${FAIL} failed ──"
[[ "$FAIL" -eq 0 ]]
