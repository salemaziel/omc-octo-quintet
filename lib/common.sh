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

# need_arg <flag> <argc> — die unless a value follows <flag> (call with "$#").
need_arg() { [[ "$2" -ge 2 ]] || die "$1 requires a value"; }

# quintet_validate_team_name <name> — team names become tmux session names and
# state dir names, so only a safe, tmux-stable subset is allowed (no '.', ':', '/').
quintet_validate_team_name() {
    [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]] \
        || die "invalid team name '${1:-}': must match ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}\$ (letter/digit first, then letters, digits, '_' or '-'; max 64 chars)"
}

# ── Team locks ─────────────────────────────────────────────────────────────────
# quintet_lock <team> — atomic mkdir lock ${QUINTET_STATE_DIR}/locks/<team>.lock
# holding the owner's pid. Serializes team creation and prune per team.
# A lock is stale only when its pid is dead (kill -0 fails); there is no age-based
# breaking, and a lock with no readable pid yet counts as held. Breaking takes a
# second mkdir mutex (<team>.lock.break) so two breakers can't both win: rm the
# stale lock, retry mkdir once. Returns 1 if the lock is held (or can't be made).
quintet_lock() {
    local dir="${QUINTET_STATE_DIR}/locks" lk pid
    lk="${dir}/$1.lock"
    mkdir -p "$dir" 2>/dev/null || return 1
    if mkdir "$lk" 2>/dev/null; then echo "$$" > "${lk}/pid"; return 0; fi
    pid="$(cat "${lk}/pid" 2>/dev/null)"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null && return 1
    mkdir "${lk}.break" 2>/dev/null || return 1
    if [[ "$(cat "${lk}/pid" 2>/dev/null)" == "$pid" ]]; then
        log WARN "breaking stale lock for '$1' (pid $pid is gone)"
        rm -rf -- "$lk"
    fi
    if mkdir "$lk" 2>/dev/null; then
        echo "$$" > "${lk}/pid"; rmdir "${lk}.break" 2>/dev/null; return 0
    fi
    rmdir "${lk}.break" 2>/dev/null
    return 1
}

# quintet_unlock <team> — release a lock this process holds (no-op otherwise).
quintet_unlock() {
    local lk="${QUINTET_STATE_DIR}/locks/$1.lock"
    [[ "$(cat "${lk}/pid" 2>/dev/null)" == "$$" ]] && rm -rf -- "$lk"
    return 0
}

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
        local s="$1" i c e
        s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\t'/\\t}"
        s="${s//$'\r'/\\r}"; s="${s//$'\b'/\\b}"; s="${s//$'\f'/\\f}"
        # Remaining C0 controls (1-31; NUL can't be in a bash string) -> \u00XX.
        for i in {1..31}; do
            printf -v c "\\$(printf '%03o' "$i")"
            [[ "$s" == *"$c"* ]] || continue
            printf -v e '\\u%04x' "$i"
            s="${s//"$c"/$e}"
        done
        printf '"%s"' "$s"
    fi
}

# now_epoch / now_iso — timestamps.
now_epoch() { date +%s; }
now_iso()   { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ensure_dir <dir> — mkdir -p with a clear error.
ensure_dir() { mkdir -p "$1" 2>/dev/null || die "cannot create dir: $1"; }
