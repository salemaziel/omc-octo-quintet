#!/usr/bin/env bash
# quintet/lib/common.sh — shared helpers: paths, logging, json, slugs.
# Source-safe: no top-level execution side effects beyond defining functions/vars.
# ─────────────────────────────────────────────────────────────────────────────

# Resolve the plugin root regardless of how a script is sourced.
# QUINTET_ROOT points at the directory that contains lib/ , bin/ , skills/ ...
if [[ -z "${QUINTET_ROOT:-}" ]]; then
    _common_self="${BASH_SOURCE[0]}"
    QUINTET_ROOT="$(cd "$(dirname "$_common_self")/.." && pwd)"
fi
export QUINTET_ROOT

# Per-project team/runtime state (worktree-local by default).
QUINTET_STATE_DIR="${QUINTET_STATE_DIR:-${PWD}/.quintet}"
# Global provider reliability state (circuit breaker etc.) lives in $HOME.
QUINTET_HOME="${QUINTET_HOME:-${HOME}/.quintet}"
export QUINTET_STATE_DIR QUINTET_HOME

# ── Logging ──────────────────────────────────────────────────────────────────
# Levels go to stderr so stdout stays clean for machine-readable output.
QUINTET_LOG_LEVEL="${QUINTET_LOG_LEVEL:-INFO}"  # DEBUG|INFO|WARN|ERROR

_q_level_num() {
    case "$1" in
        DEBUG) echo 0 ;; INFO) echo 1 ;; WARN) echo 2 ;; ERROR) echo 3 ;; *) echo 1 ;;
    esac
}

log() {
    local level="$1"; shift
    local want cur
    want=$(_q_level_num "$level")
    cur=$(_q_level_num "$QUINTET_LOG_LEVEL")
    [[ "$want" -lt "$cur" ]] && return 0
    local color reset="\033[0m"
    case "$level" in
        DEBUG) color="\033[2;37m" ;;
        INFO)  color="\033[0;36m" ;;
        WARN)  color="\033[0;33m" ;;
        ERROR) color="\033[0;31m" ;;
        *)     color="" ;;
    esac
    if [[ -t 2 ]]; then
        printf "${color}[quintet:%s]${reset} %s\n" "$level" "$*" >&2
    else
        printf "[quintet:%s] %s\n" "$level" "$*" >&2
    fi
}

die() { log ERROR "$*"; exit 1; }

# ── String / slug helpers ──────────────────────────────────────────────────────
# Turn arbitrary task text into a short, filesystem-safe team-name slug.
slugify() {
    local text="$1" max="${2:-32}"
    printf '%s' "$text" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
        | cut -c1-"$max" \
        | sed -E 's/-+$//'
}

# ── JSON helpers (jq required for structured output) ───────────────────────────
have_jq() { command -v jq >/dev/null 2>&1; }

# json_escape <string>  -> a JSON-quoted string (uses jq if present, else manual).
json_escape() {
    if have_jq; then
        printf '%s' "$1" | jq -Rs .
    else
        local s="$1"
        s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\t'/\\t}"
        printf '"%s"' "$s"
    fi
}

# now_epoch / now_iso — timestamps.
now_epoch() { date +%s; }
now_iso()   { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ensure_dir <dir> — mkdir -p with a clear error.
ensure_dir() { mkdir -p "$1" 2>/dev/null || die "cannot create dir: $1"; }
