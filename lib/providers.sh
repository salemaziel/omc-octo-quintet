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

# Single source of truth for the env var NAMES a provider's worker needs
# (auth + config). Values are never listed or logged here.
# quintet_provider_env_vars <provider> [--auth]
#   --auth : only the credential vars, in the order quintet_provider_auth checks them.
# Without --auth: credential vars, then provider config vars.
quintet_provider_env_vars() {
    local -a auth=() conf=()
    case "$1" in
        claude)
            auth=(ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN)
            conf=(ANTHROPIC_BASE_URL CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX
                  AWS_REGION AWS_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
                  AWS_SESSION_TOKEN AWS_BEARER_TOKEN_BEDROCK
                  AWS_DEFAULT_REGION AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE
                  ANTHROPIC_VERTEX_PROJECT_ID CLOUD_ML_REGION) ;;
        codex)       auth=(OPENAI_API_KEY); conf=(OPENAI_BASE_URL) ;;
        agy|gemini)  auth=(GEMINI_API_KEY GOOGLE_API_KEY) ;;
        copilot)     auth=(COPILOT_GITHUB_TOKEN GH_TOKEN GITHUB_TOKEN) ;;
        qwen)        auth=(QWEN_API_KEY) ;;
        opencode)    auth=(OPENCODE_API_KEY OPENROUTER_API_KEY) ;;
    esac
    if [[ "${2:-}" == "--auth" ]]; then
        printf '%s\n' "${auth[@]}"
    else
        printf '%s\n' "${auth[@]}" "${conf[@]}"
    fi
}

# Env var names every worker gets regardless of provider (QUINTET_* and LC_* are
# matched by prefix in quintet_write_worker_env). Workers start from an empty
# environment (env -i), so this also carries what a CLI needs: locale, user
# identity, shell, timezone, terminfo, Node options, XDG base dirs, CLI config dirs, Vertex/GCP config,
# ssh-agent/display/dbus sockets, CA bundles, proxies, editor. Non-secret names
# only. TERM is not here: a worker takes TERM/TMUX/TMUX_PANE from its own
# terminal (the tmux pane), never from the caller (R-M1).
QUINTET_COMMON_ENV_VARS=(PATH HOME TMPDIR COLORTERM LANG LANGUAGE USER LOGNAME SHELL TZ
    TERMINFO TERMINFO_DIRS NODE_OPTIONS GH_HOST
    XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME XDG_RUNTIME_DIR
    CODEX_HOME CLAUDE_CONFIG_DIR GH_CONFIG_DIR
    GOOGLE_GENAI_USE_VERTEXAI GOOGLE_CLOUD_PROJECT GOOGLE_CLOUD_LOCATION GOOGLE_APPLICATION_CREDENTIALS
    SSH_AUTH_SOCK DISPLAY WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS
    NODE_EXTRA_CA_CERTS SSL_CERT_FILE SSL_CERT_DIR REQUESTS_CA_BUNDLE
    HTTP_PROXY HTTPS_PROXY NO_PROXY ALL_PROXY http_proxy https_proxy no_proxy all_proxy
    EDITOR VISUAL)

# quintet_write_worker_env <provider> <file>
# Writes the caller's exported, allowlisted vars (common + provider's list +
# QUINTET_* / LC_*) to <file> as `declare -x NAME=<%q value>` lines, mode 0600.
# The file's dir must already be 0700. Values are never echoed or logged.
quintet_write_worker_env() {
    local provider="$1" file="$2" v
    local -A allow=()
    for v in "${QUINTET_COMMON_ENV_VARS[@]}"; do allow[$v]=1; done
    while IFS= read -r v; do [[ -n "$v" ]] && allow[$v]=1; done < <(quintet_provider_env_vars "$provider")
    (
        umask 077
        : > "$file" || exit 1
        while IFS= read -r v; do
            [[ -n "${allow[$v]:-}" || "$v" == QUINTET_* || "$v" == LC_* ]] || continue
            printf 'declare -x %s=%q\n' "$v" "${!v}"
        done < <(compgen -e) > "$file"
    )
}

# _quintet_env_enabled <VAR> — true when VAR is set to something other than
# empty/0/false (tests presence/truthiness only; the value is never printed).
_quintet_env_enabled() {
    local v="${!1:-}"
    [[ -n "$v" && "$v" != "0" && "${v,,}" != "false" ]]
}

# Report the auth method in use (best-effort, never blocks; a heuristic, not a
# login check). Echoes: oauth | api-key | cloud | gh-cli | keychain | none | unknown
# (`unknown` = could not tell; doctor shows it as "unverified").
# Credential env var names come from quintet_provider_env_vars --auth.
quintet_provider_auth() {
    local v env_hit=""
    while IFS= read -r v; do
        [[ -n "$v" && -n "${!v:-}" ]] && { env_hit="$v"; break; }
    done < <(quintet_provider_env_vars "$1" --auth)
    case "$1" in
        claude)
            # Heuristic: only `none` when no credential source is visible. On macOS
            # the credentials live in the keychain, which isn't inspected: unknown.
            # Existence checks only; no values are read.
            if [[ -n "$env_hit" ]]; then echo "api-key";
            elif [[ -f "${HOME}/.claude/.credentials.json" ]]; then echo "oauth";
            elif _quintet_env_enabled CLAUDE_CODE_USE_BEDROCK || _quintet_env_enabled CLAUDE_CODE_USE_VERTEX; then echo "cloud";
            elif [[ "$(uname -s)" == "Darwin" ]]; then echo "unknown";
            else echo "none"; fi ;;
        codex)
            if [[ -f "${HOME}/.codex/auth.json" ]]; then echo "oauth";
            elif [[ -n "$env_hit" ]]; then echo "api-key";
            else echo "none"; fi ;;
        agy|gemini)
            if [[ -n "$env_hit" ]]; then echo "api-key";
            elif [[ -f "${HOME}/.gemini/antigravity-cli/antigravity-oauth-token" || -f "${HOME}/.gemini/oauth_creds.json" ]]; then echo "oauth";
            else echo "none"; fi ;;
        copilot)
            if [[ -n "$env_hit" ]]; then echo "env:${env_hit}";
            elif [[ -f "${HOME}/.copilot/config.json" ]]; then echo "keychain";
            elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then echo "gh-cli";
            else echo "none"; fi ;;
        qwen)
            if [[ -f "${HOME}/.qwen/oauth_creds.json" ]]; then echo "oauth";
            elif [[ -f "${HOME}/.qwen/config.json" ]]; then echo "config";
            elif [[ -n "$env_hit" ]]; then echo "api-key";
            else echo "none"; fi ;;
        opencode)
            local auth_file="${XDG_DATA_HOME:-$HOME/.local/share}/opencode/auth.json"
            if [[ -s "$auth_file" ]]; then echo "oauth";
            elif [[ -n "$env_hit" ]]; then echo "api-key";
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

# quintet_provider_caps <provider> -> "mcp_off=<full|partial|none> effort=<yes|variant|no>"
# What --no-mcp and --effort can actually achieve per provider (A8, A16).
#   copilot partial: --disable-builtin-mcps only; user/workspace/plugin MCP servers
#   stay on (would need --disable-mcp-server per entry of `copilot mcp list`,
#   whose output format isn't documented in --help).
#   opencode effort=variant: mapped to --variant. qwen: flags unverified.
quintet_provider_caps() {
    case "$1" in
        claude|codex) echo "mcp_off=full effort=yes" ;;
        agy|gemini)   echo "mcp_off=none effort=yes" ;;
        copilot)      echo "mcp_off=partial effort=yes" ;;
        opencode)     echo "mcp_off=none effort=variant" ;;
        *)            echo "mcp_off=none effort=no" ;;
    esac
}

# quintet_no_mcp_effective <provider> <no_mcp> -> full|partial|none|not-requested
quintet_no_mcp_effective() {
    [[ "$2" == "true" || "$2" == "--no-mcp" ]] || { echo "not-requested"; return 0; }
    local caps; caps="$(quintet_provider_caps "$1")"; caps="${caps#mcp_off=}"
    echo "${caps%% *}"
}

# WARN when a requested option isn't fully honored by a provider.
_quintet_caps_warn() {
    local provider="$1" no_mcp="$2" effort="$3" eff
    eff="$(quintet_no_mcp_effective "$provider" "$no_mcp")"
    case "$eff" in
        partial) log WARN "$provider: --no-mcp is partial (built-in MCP servers off; user/workspace/plugin servers stay on)" ;;
        none)    log WARN "$provider: --no-mcp not supported; MCP servers stay on" ;;
    esac
    if [[ -n "$effort" && "$(quintet_provider_caps "$provider")" == *effort=no* ]]; then
        log WARN "$provider: --effort not supported; ignored"
    fi
    return 0
}

# _quintet_cli_map_get <map> <provider> — value for <provider> in
# "p=v[,p=v]" (first match wins; "gemini" is an alias of "agy").
_quintet_cli_map_get() {
    local map="$1" provider="$2" item k
    [[ "$provider" == "gemini" ]] && provider="agy"
    local -a items=()
    IFS=',' read -ra items <<< "$map"
    for item in "${items[@]}"; do
        k="${item%%=*}"; [[ "$k" == "gemini" ]] && k="agy"
        [[ "$k" == "$provider" ]] && { printf '%s' "${item#*=}"; return 0; }
    done
    return 0
}

# quintet_validate_model_value <what> <value> — die unless <value> looks like a
# model/effort name. A leading '-' would reach the CLI as an extra flag
# (e.g. --model --dangerously-skip-permissions), so values must start with a
# letter or digit (S-L4). Brackets are allowed for Claude aliases like opus[1m].
quintet_validate_model_value() {
    local re='^[A-Za-z0-9][][A-Za-z0-9._/@+:=-]*$'
    [[ "$2" =~ $re ]] \
        || die "$1: invalid value '$2' (must match $re)"
}

# quintet_parse_cli_value <flag> <value> <map_var> <bare_var>
# --model/--effort accept a bare value or "provider=value[,provider=value]".
# Stores into the named variables (map or bare); dies on a malformed map or value.
quintet_parse_cli_value() {
    local flag="$1" val="$2" item p
    local -n _qpc_map="$3" _qpc_bare="$4"
    if [[ "$val" == *=* ]]; then
        local -a items=()
        IFS=',' read -ra items <<< "$val"
        for item in "${items[@]}"; do
            p="${item%%=*}"
            [[ "$item" == *=?* ]] || die "$flag: bad entry '$item' (use provider=value[,provider=value])"
            quintet_provider_validate "$p"
            quintet_validate_model_value "$flag" "${item#*=}"
        done
        _qpc_map="${_qpc_map:+${_qpc_map},}${val}"
    else
        quintet_validate_model_value "$flag" "$val"
        _qpc_bare="$val"
    fi
}

# quintet_resolve_model <provider> <cli_map> <spec_model> [cli_bare]
# Decision 3 precedence (CLI beats env at every level):
#   per-provider CLI map > team spec model > bare --model > QUINTET_<P>_MODEL > QUINTET_MODEL
# The resolved value is validated wherever it came from (env and env-set
# QUINTET_MODEL_MAP included), so a bad value dies here (S-L4, R-L1).
quintet_resolve_model() {
    local provider="$1" map="$2" spec="$3" bare="${4:-}" v src="model for $1"
    v="$(_quintet_cli_map_get "$map" "$provider")"
    [[ -n "$v" ]] || v="$spec"
    [[ -n "$v" ]] || v="$bare"
    if [[ -z "$v" ]]; then
        local p_upper; p_upper="$(printf '%s' "$provider" | tr '[:lower:]' '[:upper:]')"
        local pv="QUINTET_${p_upper}_MODEL"
        if [[ -n "${!pv:-}" ]]; then v="${!pv}"; src="$pv"; else v="${QUINTET_MODEL:-}"; src="QUINTET_MODEL"; fi
    fi
    [[ -z "$v" ]] || quintet_validate_model_value "$src" "$v"
    printf '%s' "$v"
}

# quintet_resolve_effort <provider> <cli_map> [cli_bare]
#   per-provider CLI map > bare --effort > QUINTET_<P>_EFFORT > QUINTET_EFFORT
quintet_resolve_effort() {
    local provider="$1" map="$2" bare="${3:-}" v src="effort for $1"
    v="$(_quintet_cli_map_get "$map" "$provider")"
    [[ -n "$v" ]] || v="$bare"
    if [[ -z "$v" ]]; then
        local p_upper; p_upper="$(printf '%s' "$provider" | tr '[:lower:]' '[:upper:]')"
        local pv="QUINTET_${p_upper}_EFFORT"
        if [[ -n "${!pv:-}" ]]; then v="${!pv}"; src="$pv"; else v="${QUINTET_EFFORT:-}"; src="QUINTET_EFFORT"; fi
    fi
    [[ -z "$v" ]] || quintet_validate_model_value "$src" "$v"
    printf '%s' "$v"
}

# quintet_provider_timeout <provider> — one-shot timeout in seconds.
# Generous defaults: a cold-started headless CLI doing real reasoning routinely
# needs >120s. The earlier 90–120s ceilings were the main source of exit-124
# timeouts (compounded by agentic file-exploration, now suppressed by the
# advisory preamble in fleet.sh). Override per provider via QUINTET_<P>_TIMEOUT.
quintet_provider_timeout() {
    local t_default="${QUINTET_TIMEOUT:-240}"
    case "$1" in
        claude)      echo "${QUINTET_CLAUDE_TIMEOUT:-$t_default}" ;;
        codex)       echo "${QUINTET_CODEX_TIMEOUT:-$t_default}" ;;
        agy|gemini)  echo "${QUINTET_AGY_TIMEOUT:-${QUINTET_GEMINI_TIMEOUT:-$t_default}}" ;;
        copilot)     echo "${QUINTET_COPILOT_TIMEOUT:-$t_default}" ;;
        qwen)        echo "${QUINTET_QWEN_TIMEOUT:-$t_default}" ;;
        opencode)    echo "${QUINTET_OPENCODE_TIMEOUT:-$t_default}" ;;
        *)           echo "$t_default" ;;
    esac
}

# quintet_provider_oneshot <provider> <prompt> [no_mcp] [model] [effort] [safe_mode] [tee_to]
# Runs the CLI headless, prints the response to stdout, returns the CLI exit code.
# Honors a per-provider timeout (seconds) via QUINTET_<PROVIDER>_TIMEOUT.
# tee_to (optional): also stream the provider's stdout to this file as it
# arrives (the fleet tmux worker passes /dev/stderr so it shows in the pane).
quintet_provider_oneshot() {
    local provider="$1" prompt="$2"
    local no_mcp="${3:-${QUINTET_NO_MCP:-false}}"
    local model="${4:-}"
    local effort="${5:-}"
    local safe_mode="${6:-${QUINTET_SAFE_MODE:-false}}"
    local tee_to="${7:-}"
    [[ "$no_mcp" == "--no-mcp" ]] && no_mcp=true
    [[ "$safe_mode" == "--safe" ]] && safe_mode=true

    local p_upper; p_upper="$(printf '%s' "$provider" | tr '[:lower:]' '[:upper:]')"
    # Explicit args win; otherwise resolve CLI map/bare value (exported by the
    # fleet commands as QUINTET_{MODEL,EFFORT}_{MAP,CLI}) and env (decision 3).
    [[ -n "$model" ]]  || model="$(quintet_resolve_model "$provider" "${QUINTET_MODEL_MAP:-}" "" "${QUINTET_MODEL_CLI:-}")" || return 2
    [[ -n "$effort" ]] || effort="$(quintet_resolve_effort "$provider" "${QUINTET_EFFORT_MAP:-}" "${QUINTET_EFFORT_CLI:-}")" || return 2
    _quintet_caps_warn "$provider" "$no_mcp" "$effort"

    local timeout_secs; timeout_secs="$(quintet_provider_timeout "$provider")"

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
                # COPILOT_GITHUB_TOKEN is inherited from the environment; never
                # put it in argv (visible in /proc/*/cmdline).
                cmd=(timeout "$timeout_secs" copilot -p "$prompt" --no-ask-user -s --disable-builtin-mcps)
                [[ -n "$model" ]] && cmd+=(--model "$model")
                [[ -n "$effort" ]] && cmd+=(--reasoning-effort "$effort")
                ;;
            qwen)
                cmd=(env GEMINI_CLI_TRUST_WORKSPACE=true QWEN_CLI_TRUST_WORKSPACE=true \
                     timeout "$timeout_secs" qwen -p "$prompt")
                [[ "$safe_mode" != "true" ]] && cmd+=(--approval-mode yolo)
                cmd+=(-o text)
                [[ -n "$model" ]] && cmd+=(--model "$model")
                ;;
            opencode)
                # --pure is "no external plugins", not MCP: never used for --no-mcp.
                cmd=(timeout "$timeout_secs" opencode run)
                [[ "$safe_mode" != "true" ]] && cmd+=(--auto)
                [[ -n "$model" ]] && cmd+=(--model "$model")
                [[ -n "$effort" ]] && cmd+=(--variant "$effort")
                cmd+=("$prompt")
                ;;
            *)
                log ERROR "unknown provider for one-shot: $provider"; return 2 ;;
        esac
    fi

    # Capture stdout (the real answer) and stderr separately so verbose CLI
    # warnings (agy/qwen) don't pollute a successful response. On failure we
    # fold stderr in so the reliability layer can classify the error.
    # _q_errdir: set by the fleet caller to its run dir (C-L1).
    local errfile out code
    errfile="$(mktemp "${_q_errdir:-${TMPDIR:-/tmp}}/quintet-err-XXXXXX")"
    # The CLI runs under env -i with only the worker allowlist (same builder as
    # the tmux workers, S-M1) plus this process's own TERM/TMUX/TMUX_PANE: the
    # pane's values in a tmux fleet worker, the caller's terminal with --no-tmux.
    # The env file lives in a private 0700 dir and is deleted before exec.
    local envd envf
    envd="$(mktemp -d "${_q_errdir:-${TMPDIR:-/tmp}}/quintet-env1-XXXXXX")" || { rm -f "$errfile"; log ERROR "one-shot: cannot create env dir"; return 2; }
    envf="${envd}/${provider}.env"
    quintet_write_worker_env "$provider" "$envf" || { rm -rf -- "$envd" "$errfile"; log ERROR "one-shot: cannot write env file for $provider"; return 2; }
    local -a term_env=()
    [[ -n "${TERM:-}" ]] && term_env+=("TERM=$TERM")
    [[ -n "${TMUX:-}" ]] && term_env+=("TMUX=$TMUX")
    [[ -n "${TMUX_PANE:-}" ]] && term_env+=("TMUX_PANE=$TMUX_PANE")
    # shellcheck disable=SC2016  # $1/$@ expand in the child bash
    cmd=(env -i "${term_env[@]}" "${BASH:-bash}" --noprofile --norc -c '. "$1" || { echo "quintet: cannot read worker env file" >&2; exit 1; }; rm -f -- "$1"; shift; exec "$@"' \
         quintet-oneshot "$envf" "${cmd[@]}")
    if [[ -n "$tee_to" ]]; then
        out="$("${cmd[@]}" 2>"$errfile" | tee -a -- "$tee_to"; exit "${PIPESTATUS[0]}")"; code=$?
    else
        out="$("${cmd[@]}" 2>"$errfile")"; code=$?
    fi
    rm -rf -- "$envd"
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
# model/effort are already-resolved values (quintet_resolve_model/_effort); this
# function never reads QUINTET_*_MODEL. Output is a shell command string built
# from an argv array with printf %q, so model/effort values can't inject shell
# syntax or extra flags (C1). A custom QUINTET_<P>_LAUNCH is a documented raw
# shell override and is returned verbatim.
quintet_provider_launch_cmd() {
    local provider="$1"
    local no_mcp="${2:-${QUINTET_NO_MCP:-false}}"
    local model="${3:-}"
    local effort="${4:-}"
    local safe_mode="${5:-${QUINTET_SAFE_MODE:-false}}"
    [[ "$no_mcp" == "--no-mcp" ]] && no_mcp=true
    [[ "$safe_mode" == "--safe" ]] && safe_mode=true

    local p_upper; p_upper="$(printf '%s' "$provider" | tr '[:lower:]' '[:upper:]')"
    local custom_var="QUINTET_${p_upper}_LAUNCH" custom
    custom="${!custom_var:-}"
    [[ "$provider" == "agy" || "$provider" == "gemini" ]] && custom="${QUINTET_AGY_LAUNCH:-${QUINTET_GEMINI_LAUNCH:-}}"
    if [[ -n "$custom" ]]; then
        printf '%s\n' "$custom"; return 0
    fi
    _quintet_caps_warn "$provider" "$no_mcp" "$effort"

    local -a a=()
    case "$provider" in
        claude)
            a=(claude)
            [[ "$safe_mode" != "true" ]] && a+=(--permission-mode bypassPermissions)
            [[ "$no_mcp" == "true" ]] && a+=(--strict-mcp-config)
            [[ -n "$model" ]] && a+=(--model "$model")
            [[ -n "$effort" ]] && a+=(--effort "$effort") ;;
        codex)
            a=(codex)
            [[ "$safe_mode" != "true" ]] && a+=(--yolo)
            [[ "$no_mcp" == "true" ]] && a+=(-c 'mcp_servers={}')
            [[ -n "$model" ]] && a+=(--model "$model")
            [[ -n "$effort" ]] && a+=(-c "model_reasoning_effort=${effort}") ;;
        agy|gemini)
            a=(agy)
            [[ "$safe_mode" != "true" ]] && a+=(--dangerously-skip-permissions)
            [[ -n "$model" ]] && a+=(--model "$model")
            [[ -n "$effort" ]] && a+=(--effort "$effort") ;;
        copilot)
            # --allow-all = tools + paths + urls, so path/URL prompts don't stall
            # workers (A15). Nothing under --safe.
            a=(copilot)
            [[ "$safe_mode" != "true" ]] && a+=(--allow-all)
            [[ "$no_mcp" == "true" ]] && a+=(--disable-builtin-mcps)
            [[ -n "$model" ]] && a+=(--model "$model")
            [[ -n "$effort" ]] && a+=(--reasoning-effort "$effort") ;;
        qwen)
            a=(env GEMINI_CLI_TRUST_WORKSPACE=true QWEN_CLI_TRUST_WORKSPACE=true qwen)
            [[ "$safe_mode" != "true" ]] && a+=(--approval-mode yolo)
            [[ -n "$model" ]] && a+=(--model "$model") ;;
        opencode)
            # --pure is "no external plugins", not MCP: never used for --no-mcp.
            a=(opencode)
            [[ "$safe_mode" != "true" ]] && a+=(--auto)
            [[ -n "$model" ]] && a+=(--model "$model")
            [[ -n "$effort" ]] && a+=(--variant "$effort") ;;
        *)
            a=("$(quintet_provider_bin "$provider")") ;;
    esac
    local s; s="$(printf '%q ' "${a[@]}")"
    printf '%s\n' "${s% }"
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
