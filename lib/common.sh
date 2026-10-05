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

# ── State dir safety ───────────────────────────────────────────────────────────
# State paths are never followed through symlinks: a pre-placed symlink (e.g. a
# cloned repo's .quintet/teams -> ../..) would otherwise make prune or shutdown
# rm -rf outside the state dir, or make team start write through to other files.

# quintet_refuse_symlink <path> <what> — die if <path> is a symlink.
quintet_refuse_symlink() {
    [[ -L "${1%/}" ]] && die "refusing to use $2 '${1%/}': it is a symlink (remove it, or point QUINTET_STATE_DIR / QUINTET_HOME at a real directory)"
    return 0
}

# quintet_state_guard [team] — die if QUINTET_STATE_DIR, its teams/ or locks/,
# or the team's dir is a symlink.
# shellcheck disable=SC2120  # team.sh passes the team name; other callers don't
quintet_state_guard() {
    local s="${QUINTET_STATE_DIR%/}"
    quintet_refuse_symlink "$s" "QUINTET_STATE_DIR"
    quintet_refuse_symlink "$s/teams" "state dir"
    quintet_refuse_symlink "$s/locks" "lock dir"
    [[ -n "${1:-}" ]] && quintet_refuse_symlink "$s/teams/$1" "team dir"
    return 0
}

# quintet_safe_rm_dir <dir> <base> — rm -rf <dir> only when it is a real
# (non-symlink) directory owned by this user whose resolved path is directly
# under the resolved <base> (itself not a symlink). Returns 1 without removing
# anything otherwise, or when rm fails.
quintet_safe_rm_dir() {
    local d="${1%/}" base="${2%/}" rd rb
    [[ -d "$d" && ! -L "$d" && -O "$d" && -d "$base" && ! -L "$base" ]] || return 1
    rd="$(cd -P -- "$d" 2>/dev/null && pwd -P)" || return 1
    rb="$(cd -P -- "$base" 2>/dev/null && pwd -P)" || return 1
    [[ "${rd%/*}" == "$rb" && "$rd" != "$rb" ]] || return 1
    rm -rf -- "$rd" 2>/dev/null && [[ ! -e "$rd" ]]
}

# ── Team locks ─────────────────────────────────────────────────────────────────
# quintet_lock <team> — lock dir ${QUINTET_STATE_DIR}/locks/<team>.lock holding
# the owner's pid. Serializes team creation and prune per team.
# The lock appears atomically with its pid: the pid is written into a temp dir
# that is then renamed into place, so a pid-less lock is never created (rename
# fails if a non-empty lock exists; an empty leftover dir is replaced).
# A lock is stale only when its pid is dead (kill -0 fails); there is no age-based
# breaking. Breaking takes a second lock (<team>.lock.break, made the same way,
# with its own pid) so two breakers can't both win: move the stale lock aside, retry
# once. A .break dir whose pid is dead is itself stale: a breaker claims it (mkdir
# <team>.lock.break/claim, exclusive), re-checks its pid, and moves it aside. Stale
# dirs are renamed to a unique *.dead.* name and only then rm'd, so a live dir that
# replaced a stale one is never removed (R-L4). Returns 1 if the lock is held (or
# can't be made), 2 if there is no rename primitive (GNU mv or python3). Dies if a
# state path is a symlink.
quintet_lock_path() { echo "${QUINTET_STATE_DIR%/}/locks/$1.lock"; }

# _quintet_can_rename — true if _quintet_rename has a method (GNU mv -T or python3).
_quintet_can_rename() {
    mv --help 2>&1 | grep -q -- '--no-target-directory' || command -v python3 >/dev/null 2>&1
}

# _quintet_rename <src> <dst> — rename(2) <src> to <dst>: never follows a <dst>
# symlink (the link itself is replaced); fails if <dst> is a non-empty dir.
# GNU mv -T, else python3 os.rename.
_quintet_rename() {
    if mv --help 2>&1 | grep -q -- '--no-target-directory'; then
        mv -T -- "$1" "$2" 2>/dev/null
    else
        python3 -c 'import os,sys; os.rename(sys.argv[1], sys.argv[2])' "$1" "$2" 2>/dev/null
    fi
}

# _quintet_lock_take <lockdir> — create <lockdir> containing pid=$$, atomically.
_quintet_lock_take() {
    local tmp
    tmp="$(mktemp -d "${1}.tmp.XXXXXX" 2>/dev/null)" || return 1
    if echo "$$" > "${tmp}/pid" && _quintet_rename "$tmp" "$1"; then return 0; fi
    rm -rf -- "$tmp"
    return 1
}

# _quintet_lock_discard <dir> — rename <dir> to a unique <dir>.dead.* name, then
# rm it. Nonzero (nothing removed) if the rename fails, e.g. <dir> is gone.
_quintet_lock_discard() {
    local dead
    dead="$(mktemp -d "${1}.dead.XXXXXX" 2>/dev/null)" || return 1
    if _quintet_rename "$1" "$dead"; then rm -rf -- "$dead"; return 0; fi
    rmdir -- "$dead" 2>/dev/null
    return 1
}

quintet_lock() {
    local dir lk pid bpid
    quintet_state_guard
    _quintet_can_rename || return 2
    dir="${QUINTET_STATE_DIR%/}/locks"; lk="$(quintet_lock_path "$1")"
    mkdir -p "$dir" 2>/dev/null || return 1
    _quintet_lock_take "$lk" && return 0
    pid="$(cat "${lk}/pid" 2>/dev/null)"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null && return 1
    if ! _quintet_lock_take "${lk}.break"; then
        bpid="$(cat "${lk}.break/pid" 2>/dev/null)"
        [[ "$bpid" =~ ^[0-9]+$ ]] || return 1
        kill -0 "$bpid" 2>/dev/null && return 1
        # One breaker wins the claim. The pid re-check after it catches a claim
        # that landed in a live .break which replaced the stale one.
        mkdir -- "${lk}.break/claim" 2>/dev/null || return 1
        if [[ "$(cat "${lk}.break/pid" 2>/dev/null)" != "$bpid" ]]; then
            rmdir -- "${lk}.break/claim" 2>/dev/null; return 1
        fi
        log WARN "removing stale lock-break dir for '$1' (pid $bpid is gone)"
        _quintet_lock_discard "${lk}.break" || return 1
        _quintet_lock_take "${lk}.break" || return 1
    fi
    if [[ "$(cat "${lk}/pid" 2>/dev/null)" == "$pid" ]]; then
        log WARN "breaking stale lock for '$1' (pid $pid is gone)"
        _quintet_lock_discard "$lk"
    fi
    if _quintet_lock_take "$lk"; then
        rm -rf -- "${lk}.break"; return 0
    fi
    rm -rf -- "${lk}.break"
    return 1
}

# quintet_unlock <team> — release a lock this process holds (no-op otherwise).
quintet_unlock() {
    local lk; lk="$(quintet_lock_path "$1")"
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
