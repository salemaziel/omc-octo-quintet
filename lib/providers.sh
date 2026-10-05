#!/usr/bin/env bash
# quintet/lib/providers.sh — the provider registry.
#
# This is the single source of truth for how quintet talks to each coding-agent
# CLI. Adding a new provider = adding one entry to QUINTET_PROVIDERS plus the
# matching helper functions below. Nothing else in the codebase hardcodes a CLI
# name.
#
# For each provider we define two execution contracts:
#   1. ONE-SHOT  (headless / programmatic) — used by the fleet dispatcher.
#   2. INTERACTIVE (REPL launch + task injection) — used by the tmux team runtime.
#
# Invocation contracts below were verified against the live CLIs:
#   claude   : claude -p "<prompt>"                            (Claude Code print mode)
#   codex    : codex exec "<prompt>"                            (non-interactive)
#   agy      : agy -p "<prompt>" --dangerously-skip-permissions --output-format text
#   copilot  : copilot -p "<prompt>" --no-ask-user -s --disable-builtin-mcps
#   qwen     : qwen -p "<prompt>" --approval-mode yolo -o text  (Gemini-CLI fork)
#   opencode : opencode run "<prompt>" --pure --auto
# ─────────────────────────────────────────────────────────────────────────────

# Canonical provider list (extend here to add ollama/cursor-agent/etc.).
QUINTET_PROVIDERS=(claude codex agy copilot qwen opencode)

# Display emoji per provider (used in fleet reports).
quintet_provider_emoji() {
    case "$1" in
        claude)      echo "🟣" ;;
        codex)       echo "🔴" ;;
        agy|gemini)  echo "🟡" ;;
        copilot)     echo "🟢" ;;
        qwen)        echo "🔵" ;;
        opencode)    echo "🟧" ;;
        *)           echo "⚪" ;;
    esac
}

# The binary name to look for on PATH for a given provider.
quintet_provider_bin() {
    case "$1" in
        claude)      echo "claude" ;;
        codex)       echo "codex" ;;
        agy|gemini)  echo "agy" ;;
        copilot)     echo "copilot" ;;
        qwen)        echo "qwen" ;;
        opencode)    echo "opencode" ;;
        *)           echo "$1" ;;
    esac
}

# Install hint shown by `quintet doctor` when a CLI is missing.
quintet_provider_install_hint() {
    case "$1" in
        claude)      echo "npm install -g @anthropic-ai/claude-code" ;;
        codex)       echo "npm install -g @openai/codex" ;;
        agy|gemini)  echo "Google Antigravity CLI (agy)" ;;
        copilot)     echo "npm install -g @github/copilot  (or: brew install copilot-cli)" ;;
        qwen)        echo "npm install -g @qwen-code/qwen-code" ;;
        opencode)    echo "npm install -g @opencode/cli  (or: curl -fsSL https://opencode.ai/install | bash)" ;;
        *)           echo "(unknown provider)" ;;
    esac
}

# True if the CLI binary is installed.
quintet_provider_installed() {
    command -v "$(quintet_provider_bin "$1")" >/dev/null 2>&1
}

# Report the auth method in use (best-effort, never blocks).
# Echoes a short token: oauth | api-key | gh-cli | keychain | none | unknown
quintet_provider_auth() {
    case "$1" in
        claude)
            # Claude Code: subscription/OAuth in ~/.claude or ANTHROPIC_API_KEY.
            if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then echo "api-key";
            elif [[ -f "${HOME}/.claude/.credentials.json" || -d "${HOME}/.claude" ]]; then echo "oauth";
            else echo "unknown"; fi ;;
        codex)
            if [[ -f "${HOME}/.codex/auth.json" ]]; then echo "oauth";
            elif [[ -n "${OPENAI_API_KEY:-}" ]]; then echo "api-key";
            else echo "none"; fi ;;
        agy|gemini)
            if [[ -n "${GEMINI_API_KEY:-}${GOOGLE_API_KEY:-}" ]]; then echo "api-key";
            elif [[ -f "${HOME}/.gemini/oauth_creds.json" || -f "${HOME}/.gemini/google_accounts.json" || -d "${HOME}/.gemini/antigravity-cli" || -d "${HOME}/.gemini" ]]; then echo "oauth";
            else echo "unknown"; fi ;;
        copilot)
            if [[ -n "${COPILOT_GITHUB_TOKEN:-}" ]]; then echo "env:COPILOT_GITHUB_TOKEN";
            elif [[ -n "${GH_TOKEN:-}" ]]; then echo "env:GH_TOKEN";
            elif [[ -n "${GITHUB_TOKEN:-}" ]]; then echo "env:GITHUB_TOKEN";
            elif [[ -f "${HOME}/.copilot/config.json" ]]; then echo "keychain";
            elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then echo "gh-cli";
            else echo "none"; fi ;;
        qwen)
            if [[ -f "${HOME}/.qwen/oauth_creds.json" ]]; then echo "oauth";
            elif [[ -f "${HOME}/.qwen/config.json" ]]; then echo "config";
            elif [[ -n "${QWEN_API_KEY:-}" ]]; then echo "api-key";
            else echo "none"; fi ;;
        opencode)
            local auth_file="${XDG_DATA_HOME:-$HOME/.local/share}/opencode/auth.json"
            if [[ -s "$auth_file" ]]; then echo "oauth";
            elif [[ -n "${OPENCODE_API_KEY:-}${OPENROUTER_API_KEY:-}" ]]; then echo "api-key";
            else echo "none"; fi ;;
        *) echo "unknown" ;;
    esac
}

# True if provider looks ready to use (installed AND not obviously unauthenticated).
quintet_provider_ready() {
    quintet_provider_installed "$1" || return 1
    local auth; auth=$(quintet_provider_auth "$1")
    [[ "$auth" == "none" ]] && return 1
    return 0
}

# quintet_provider_oneshot <provider> <prompt> [no_mcp] [model] [effort] [safe_mode]
# Runs the CLI headless, prints the response to stdout, returns the CLI exit code.
# Honors a per-provider timeout (seconds) via QUINTET_<PROVIDER>_TIMEOUT.
quintet_provider_oneshot() {
    local provider="$1" prompt="$2"
    local no_mcp="${3:-${QUINTET_NO_MCP:-false}}"
    local model="${4:-${QUINTET_MODEL:-}}"
    local effort="${5:-${QUINTET_EFFORT:-}}"
    local safe_mode="${6:-${QUINTET_SAFE_MODE:-false}}"
    [[ "$no_mcp" == "--no-mcp" ]] && no_mcp=true
    [[ "$safe_mode" == "--safe" ]] && safe_mode=true

    local p_upper; p_upper="$(printf '%s' "$provider" | tr '[:lower:]' '[:upper:]')"
    local prov_model_var="QUINTET_${p_upper}_MODEL"
    [[ -n "${!prov_model_var:-}" ]] && model="${!prov_model_var}"

    local prov_effort_var="QUINTET_${p_upper}_EFFORT"
    [[ -n "${!prov_effort_var:-}" ]] && effort="${!prov_effort_var}"

    # Generous defaults: a cold-started headless CLI doing real reasoning routinely
    # needs >120s. The earlier 90–120s ceilings were the main source of exit-124
    # timeouts (compounded by agentic file-exploration, now suppressed by the
    # advisory preamble in fleet.sh). Override per provider via QUINTET_<P>_TIMEOUT.
    local t_default="${QUINTET_TIMEOUT:-240}"
    local timeout_secs
    case "$provider" in
        claude)      timeout_secs="${QUINTET_CLAUDE_TIMEOUT:-$t_default}" ;;
        codex)       timeout_secs="${QUINTET_CODEX_TIMEOUT:-$t_default}" ;;
        agy|gemini)  timeout_secs="${QUINTET_AGY_TIMEOUT:-${QUINTET_GEMINI_TIMEOUT:-$t_default}}" ;;
        copilot)     timeout_secs="${QUINTET_COPILOT_TIMEOUT:-$t_default}" ;;
        qwen)        timeout_secs="${QUINTET_QWEN_TIMEOUT:-$t_default}" ;;
        opencode)    timeout_secs="${QUINTET_OPENCODE_TIMEOUT:-$t_default}" ;;
        *)           timeout_secs="$t_default" ;;
    esac

    # Build the command (and any env prefix) per provider into an array.
    local -a cmd=()
    local custom_cmd_var="QUINTET_${p_upper}_ONESHOT_CMD"
    if [[ -n "${!custom_cmd_var:-}" ]]; then
        cmd=(bash -c "${!custom_cmd_var}")
    else
        case "$provider" in
            claude)
                cmd=(timeout "$timeout_secs" claude -p "$prompt")
                [[ "$no_mcp" == "true" ]] && cmd+=(--strict-mcp-config)
                [[ -n "$model" ]] && cmd+=(--model "$model")
                [[ -n "$effort" ]] && cmd+=(--effort "$effort")
                ;;
            codex)
                cmd=(timeout "$timeout_secs" codex exec "$prompt")
                [[ "$no_mcp" == "true" ]] && cmd+=(-c mcp_servers={})
                [[ -n "$model" ]] && cmd+=(--model "$model")
                [[ -n "$effort" ]] && cmd+=(-c "model_reasoning_effort=${effort}")
                ;;
            agy|gemini)
                cmd=(timeout "$timeout_secs" agy -p "$prompt")
                [[ "$safe_mode" != "true" ]] && cmd+=(--dangerously-skip-permissions)
                cmd+=(--output-format text)
                [[ -n "$model" ]] && cmd+=(--model "$model")
                [[ -n "$effort" ]] && cmd+=(--effort "$effort")
                ;;
            copilot)
                if [[ -n "${COPILOT_GITHUB_TOKEN:-}" ]]; then
                    cmd=(env "COPILOT_GITHUB_TOKEN=${COPILOT_GITHUB_TOKEN}")
                fi
                cmd+=(timeout "$timeout_secs" copilot -p "$prompt" --no-ask-user -s --disable-builtin-mcps)
                [[ -n "$model" ]] && cmd+=(--model "$model")
                ;;
            qwen)
                cmd=(env GEMINI_CLI_TRUST_WORKSPACE=true QWEN_CLI_TRUST_WORKSPACE=true \
                     timeout "$timeout_secs" qwen -p "$prompt")
                [[ "$safe_mode" != "true" ]] && cmd+=(--approval-mode yolo)
                cmd+=(-o text)
                [[ -n "$model" ]] && cmd+=(--model "$model")
                ;;
            opencode)
                cmd=(timeout "$timeout_secs" opencode run)
                [[ "$no_mcp" == "true" ]] && cmd+=(--pure)
                [[ "$safe_mode" != "true" ]] && cmd+=(--auto)
                [[ -n "$model" ]] && cmd+=(--model "$model")
                cmd+=("$prompt")
                ;;
            *)
                log ERROR "unknown provider for one-shot: $provider"; return 2 ;;
        esac
    fi

    # Capture stdout (the real answer) and stderr separately so verbose CLI
    # warnings (agy/qwen) don't pollute a successful response. On failure we
    # fold stderr in so the reliability layer can classify the error.
    local errfile out code
    errfile="$(mktemp "${TMPDIR:-/tmp}/quintet-err.XXXXXX")"
    out="$("${cmd[@]}" 2>"$errfile")"; code=$?
    if [[ $code -ne 0 ]]; then
        printf '%s\n%s' "$out" "$(cat "$errfile")"
    else
        printf '%s' "$out"
    fi
    rm -f "$errfile"
    return $code
}

# ── INTERACTIVE launch (for tmux team workers) ─────────────────────────────────
# quintet_provider_launch_cmd <provider> [no_mcp] [model] [effort] [safe_mode]
quintet_provider_launch_cmd() {
    local provider="$1"
    local no_mcp="${2:-${QUINTET_NO_MCP:-false}}"
    local model="${3:-${QUINTET_MODEL:-}}"
    local effort="${4:-${QUINTET_EFFORT:-}}"
    local safe_mode="${5:-${QUINTET_SAFE_MODE:-false}}"
    [[ "$no_mcp" == "--no-mcp" ]] && no_mcp=true
    [[ "$safe_mode" == "--safe" ]] && safe_mode=true

    local p_upper; p_upper="$(printf '%s' "$provider" | tr '[:lower:]' '[:upper:]')"
    local prov_model_var="QUINTET_${p_upper}_MODEL"
    [[ -n "${!prov_model_var:-}" ]] && model="${!prov_model_var}"

    local prov_effort_var="QUINTET_${p_upper}_EFFORT"
    [[ -n "${!prov_effort_var:-}" ]] && effort="${!prov_effort_var}"

    case "$provider" in
        claude)
            if [[ -n "${QUINTET_CLAUDE_LAUNCH:-}" ]]; then
                echo "$QUINTET_CLAUDE_LAUNCH"
            else
                local cmd="claude"
                [[ "$safe_mode" != "true" ]] && cmd+=" --permission-mode bypassPermissions"
                [[ "$no_mcp" == "true" ]] && cmd+=" --strict-mcp-config"
                [[ -n "$model" ]] && cmd+=" --model ${model}"
                [[ -n "$effort" ]] && cmd+=" --effort ${effort}"
                echo "$cmd"
            fi ;;
        codex)
            if [[ -n "${QUINTET_CODEX_LAUNCH:-}" ]]; then
                echo "$QUINTET_CODEX_LAUNCH"
            else
                local cmd="codex"
                [[ "$safe_mode" != "true" ]] && cmd+=" --yolo"
                [[ "$no_mcp" == "true" ]] && cmd+=" -c mcp_servers={}"
                [[ -n "$model" ]] && cmd+=" --model ${model}"
                [[ -n "$effort" ]] && cmd+=" -c model_reasoning_effort=${effort}"
                echo "$cmd"
            fi ;;
        agy|gemini)
            if [[ -n "${QUINTET_AGY_LAUNCH:-${QUINTET_GEMINI_LAUNCH:-}}" ]]; then
                echo "${QUINTET_AGY_LAUNCH:-$QUINTET_GEMINI_LAUNCH}"
            else
                local cmd="agy"
                [[ "$safe_mode" != "true" ]] && cmd+=" --dangerously-skip-permissions"
                [[ -n "$model" ]] && cmd+=" --model ${model}"
                [[ -n "$effort" ]] && cmd+=" --effort ${effort}"
                echo "$cmd"
            fi ;;
        copilot)
            if [[ -n "${QUINTET_COPILOT_LAUNCH:-}" ]]; then
                echo "$QUINTET_COPILOT_LAUNCH"
            else
                local cmd="copilot"
                [[ "$safe_mode" != "true" ]] && cmd+=" --allow-all-tools"
                [[ "$no_mcp" == "true" ]] && cmd+=" --disable-builtin-mcps"
                [[ -n "$model" ]] && cmd+=" --model ${model}"
                echo "$cmd"
            fi ;;
        qwen)
            if [[ -n "${QUINTET_QWEN_LAUNCH:-}" ]]; then
                echo "$QUINTET_QWEN_LAUNCH"
            else
                local cmd="env GEMINI_CLI_TRUST_WORKSPACE=true QWEN_CLI_TRUST_WORKSPACE=true qwen"
                [[ "$safe_mode" != "true" ]] && cmd+=" --approval-mode yolo"
                [[ -n "$model" ]] && cmd+=" --model ${model}"
                echo "$cmd"
            fi ;;
        opencode)
            if [[ -n "${QUINTET_OPENCODE_LAUNCH:-}" ]]; then
                echo "$QUINTET_OPENCODE_LAUNCH"
            else
                local cmd="opencode"
                [[ "$no_mcp" == "true" ]] && cmd+=" --pure"
                [[ "$safe_mode" != "true" ]] && cmd+=" --auto"
                [[ -n "$model" ]] && cmd+=" --model ${model}"
                echo "$cmd"
            fi ;;
        *)
            echo "$(quintet_provider_bin "$provider")" ;;
    esac
}

# Seconds to wait after launching the REPL before injecting the task (cold start).
quintet_provider_warmup() {
    case "$1" in
        claude)      echo "${QUINTET_CLAUDE_WARMUP:-6}" ;;
        codex)       echo "${QUINTET_CODEX_WARMUP:-5}" ;;
        agy|gemini)  echo "${QUINTET_AGY_WARMUP:-${QUINTET_GEMINI_WARMUP:-5}}" ;;
        copilot)     echo "${QUINTET_COPILOT_WARMUP:-6}" ;;
        qwen)        echo "${QUINTET_QWEN_WARMUP:-5}" ;;
        opencode)    echo "${QUINTET_OPENCODE_WARMUP:-5}" ;;
        *)           echo 5 ;;
    esac
}

# Validate a provider token; die with a helpful message if unknown.
# "gemini" is accepted as a backwards-compatible alias for "agy".
quintet_provider_validate() {
    local p="$1"
    [[ "$p" == "gemini" ]] && return 0
    for known in "${QUINTET_PROVIDERS[@]}"; do
        [[ "$p" == "$known" ]] && return 0
    done
    die "unsupported provider: '$p' (supported: ${QUINTET_PROVIDERS[*]})"
}
