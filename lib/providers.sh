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
# Invocation contracts below were verified against the live CLIs (Feb 2026):
#   claude   : claude -p "<prompt>"                            (Claude Code print mode)
#   codex    : codex exec "<prompt>"                            (non-interactive)
#   gemini   : gemini -p "<prompt>" --approval-mode yolo -o text
#   copilot  : copilot -p "<prompt>" --no-ask-user -s --disable-builtin-mcps
#   qwen     : qwen -p "<prompt>" --approval-mode yolo -o text  (Gemini-CLI fork)
# ─────────────────────────────────────────────────────────────────────────────

# Canonical provider list (extend here to add ollama/cursor-agent/etc.).
QUINTET_PROVIDERS=(claude codex gemini copilot qwen)

# Display emoji per provider (used in fleet reports).
quintet_provider_emoji() {
    case "$1" in
        claude)  echo "🟣" ;;
        codex)   echo "🔴" ;;
        gemini)  echo "🟡" ;;
        copilot) echo "🟢" ;;
        qwen)    echo "🔵" ;;
        *)       echo "⚪" ;;
    esac
}

# The binary name to look for on PATH for a given provider.
quintet_provider_bin() {
    case "$1" in
        claude)  echo "claude" ;;
        codex)   echo "codex" ;;
        gemini)  echo "gemini" ;;
        copilot) echo "copilot" ;;
        qwen)    echo "qwen" ;;
        *)       echo "$1" ;;
    esac
}

# Install hint shown by `quintet doctor` when a CLI is missing.
quintet_provider_install_hint() {
    case "$1" in
        claude)  echo "npm install -g @anthropic-ai/claude-code" ;;
        codex)   echo "npm install -g @openai/codex" ;;
        gemini)  echo "npm install -g @google/gemini-cli" ;;
        copilot) echo "npm install -g @github/copilot  (or: brew install copilot-cli)" ;;
        qwen)    echo "npm install -g @qwen-code/qwen-code" ;;
        *)       echo "(unknown provider)" ;;
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
        gemini)
            if [[ -n "${GEMINI_API_KEY:-}${GOOGLE_API_KEY:-}" ]]; then echo "api-key";
            elif [[ -d "${HOME}/.gemini" ]]; then echo "oauth";
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

# ── ONE-SHOT dispatch ──────────────────────────────────────────────────────────
# quintet_provider_oneshot <provider> <prompt>
# Runs the CLI headless, prints the response to stdout, returns the CLI exit code.
# Honors a per-provider timeout (seconds) via QUINTET_<PROVIDER>_TIMEOUT.
quintet_provider_oneshot() {
    local provider="$1" prompt="$2"
    local t_default="${QUINTET_TIMEOUT:-120}"
    local timeout_secs
    case "$provider" in
        claude)  timeout_secs="${QUINTET_CLAUDE_TIMEOUT:-$t_default}" ;;
        codex)   timeout_secs="${QUINTET_CODEX_TIMEOUT:-$t_default}" ;;
        gemini)  timeout_secs="${QUINTET_GEMINI_TIMEOUT:-$t_default}" ;;
        copilot) timeout_secs="${QUINTET_COPILOT_TIMEOUT:-90}" ;;
        qwen)    timeout_secs="${QUINTET_QWEN_TIMEOUT:-90}" ;;
        *)       timeout_secs="$t_default" ;;
    esac

    # Build the command (and any env prefix) per provider into an array.
    local -a cmd=()
    case "$provider" in
        claude)
            cmd=(timeout "$timeout_secs" claude -p "$prompt") ;;
        codex)
            cmd=(timeout "$timeout_secs" codex exec "$prompt") ;;
        gemini)
            cmd=(timeout "$timeout_secs" gemini -p "$prompt" --approval-mode yolo --skip-trust -o text) ;;
        copilot)
            # Forward whichever GitHub token is set (env wins over keychain/gh).
            if [[ -n "${COPILOT_GITHUB_TOKEN:-}" ]]; then
                cmd=(env "COPILOT_GITHUB_TOKEN=${COPILOT_GITHUB_TOKEN}")
            fi
            cmd+=(timeout "$timeout_secs" copilot -p "$prompt" --no-ask-user -s --disable-builtin-mcps) ;;
        qwen)
            # Qwen is a Gemini-CLI fork without --skip-trust; it honors the trust env var.
            cmd=(env GEMINI_CLI_TRUST_WORKSPACE=true QWEN_CLI_TRUST_WORKSPACE=true \
                 timeout "$timeout_secs" qwen -p "$prompt" --approval-mode yolo -o text) ;;
        *)
            log ERROR "unknown provider for one-shot: $provider"; return 2 ;;
    esac

    # Capture stdout (the real answer) and stderr separately so verbose CLI
    # warnings (gemini/qwen) don't pollute a successful response. On failure we
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
# quintet_provider_launch_cmd <provider> — echoes the shell command that starts
# the provider's REPL/agent in a tmux pane. The task is injected separately via
# send-keys after the REPL is ready (see lib/team.sh). Args are overridable so
# users can tune autonomy/permissions per provider.
quintet_provider_launch_cmd() {
    local provider="$1"
    case "$provider" in
        claude)  echo "${QUINTET_CLAUDE_LAUNCH:-claude --permission-mode bypassPermissions}" ;;
        codex)   echo "${QUINTET_CODEX_LAUNCH:-codex --yolo}" ;;
        gemini)  echo "${QUINTET_GEMINI_LAUNCH:-gemini --approval-mode yolo --skip-trust}" ;;
        copilot) echo "${QUINTET_COPILOT_LAUNCH:-copilot --allow-all-tools}" ;;
        qwen)    echo "${QUINTET_QWEN_LAUNCH:-qwen --approval-mode yolo}" ;;
        *)       echo "$(quintet_provider_bin "$provider")" ;;
    esac
}

# Seconds to wait after launching the REPL before injecting the task (cold start).
quintet_provider_warmup() {
    case "$1" in
        claude)  echo "${QUINTET_CLAUDE_WARMUP:-6}" ;;
        codex)   echo "${QUINTET_CODEX_WARMUP:-5}" ;;
        gemini)  echo "${QUINTET_GEMINI_WARMUP:-5}" ;;
        copilot) echo "${QUINTET_COPILOT_WARMUP:-6}" ;;
        qwen)    echo "${QUINTET_QWEN_WARMUP:-5}" ;;
        *)       echo 5 ;;
    esac
}

# Validate a provider token; die with a helpful message if unknown.
quintet_provider_validate() {
    local p="$1"
    for known in "${QUINTET_PROVIDERS[@]}"; do
        [[ "$p" == "$known" ]] && return 0
    done
    die "unsupported provider: '$p' (supported: ${QUINTET_PROVIDERS[*]})"
}
