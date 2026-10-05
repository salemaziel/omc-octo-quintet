#!/usr/bin/env bash
# quintet/lib/reliability.sh — provider reliability layer.
#
# Error classification + circuit breaker + fallback selection. Adapted from the
# claude-octopus provider-router model, trimmed to what the fleet dispatcher needs.
# State lives under $QUINTET_HOME/provider-state so it persists across processes.
# ─────────────────────────────────────────────────────────────────────────────

_Q_PSTATE="${QUINTET_HOME}/provider-state"

QUINTET_CB_FAILURE_THRESHOLD="${QUINTET_CB_FAILURE_THRESHOLD:-3}"  # transient fails before opening
QUINTET_CB_COOLDOWN_SECS="${QUINTET_CB_COOLDOWN_SECS:-300}"        # 5 min cooldown
QUINTET_CB_FAILURE_WINDOW_SECS="${QUINTET_CB_FAILURE_WINDOW_SECS:-900}"  # only count fails this recent (15 min)
QUINTET_QUOTA_TTL_SECS="${QUINTET_QUOTA_TTL_SECS:-3600}"           # skip a provider out of quota for 1 h

# _quintet_classify_text <lowercased text> -> "transient" | "permanent" | "" (no match).
# Status codes count only next to http/status/error/code or their reason phrase,
# so an answer that says "fixed 404 pages" isn't read as a permanent failure.
_quintet_classify_text() {
    local text="$1"
    if printf '%s' "$text" | grep -qE '(http|status|error|code)[^a-z0-9]{0,3}(429|5[0-9]{2})([^0-9]|$)|(429|5[0-9]{2}) (too many requests|internal server error|bad gateway|service unavailable|gateway time)|rate.?limit|too many requests|overloaded|service unavailable|bad gateway|gateway time-?out|temporarily unavailable|at capacity|connection (refused|reset)|econnreset|econnrefused|etimedout|socket hang up|network error|timed out'; then
        echo "transient"; return 0
    fi
    if printf '%s' "$text" | grep -qE '(http|status|error|code)[^a-z0-9]{0,3}(400|401|403|404)([^0-9]|$)|(400|401|403|404) (bad request|unauthorized|forbidden|not found)|unauthorized|forbidden|invalid.?api.?key|authentication (failed|required|error)|billing|payment required|quota exceeded|insufficient.?(quota|credits|funds)|invalid model|model not found|unknown model|quintet: prompt too large'; then
        echo "permanent"; return 0
    fi
    return 0
}

# classify_error <exit_code> <output_text> [stderr_text] -> "transient" | "permanent"
# stderr is checked first; the output text only when stderr says nothing.
classify_error() {
    local code="${1:-1}" out err class
    [[ "$code" == "124" ]] && { echo "transient"; return 0; }   # supervisor timeout
    out=$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')
    err=$(printf '%s' "${3:-}" | tr '[:upper:]' '[:lower:]')
    class="$(_quintet_classify_text "$err")"
    [[ -n "$class" ]] || class="$(_quintet_classify_text "$out")"
    echo "${class:-transient}"   # unknown -> safe to retry
}

# record_failure <provider> <exit_code> <output_text> [stderr_text] -> echoes the error class.
record_failure() {
    local provider="$1" code="${2:-1}" text="${3:-}" errtext="${4:-}"
    ensure_dir "$_Q_PSTATE"
    local class; class=$(classify_error "$code" "$text" "$errtext")
    local ts; ts=$(now_epoch)
    local f="${_Q_PSTATE}/${provider}.failures"
    echo "${ts}:${class}:${code}" >> "$f"
    tail -20 "$f" > "${f}.tmp" 2>/dev/null && mv "${f}.tmp" "$f"
    if [[ "$class" == "transient" ]]; then
        # Only count transient failures inside the recent window. Without this,
        # stale failures (minutes-to-days old) accumulate in the file and pre-trip
        # the breaker on an otherwise-healthy run — the exact bug where codex /
        # copilot opened "3 transient failures" before round 1 even dispatched.
        local cutoff=$(( ts - QUINTET_CB_FAILURE_WINDOW_SECS ))
        local recent
        recent=$(awk -F: -v c="$cutoff" '$1 >= c && $2 == "transient" { n++ } END { print n+0 }' "$f" 2>/dev/null || echo 0)
        if [[ "$recent" -ge "$QUINTET_CB_FAILURE_THRESHOLD" ]]; then
            echo "$ts" > "${_Q_PSTATE}/${provider}.cooldown"
            log WARN "circuit breaker OPEN for $provider ($recent transient failures in ${QUINTET_CB_FAILURE_WINDOW_SECS}s, cooling down ${QUINTET_CB_COOLDOWN_SECS}s)"
        fi
    fi
    echo "$class"
}

# record_success <provider> — clears failure state, any open breaker and a quota mark.
record_success() {
    local provider="$1"
    rm -f "${_Q_PSTATE}/${provider}.failures" "${_Q_PSTATE}/${provider}.cooldown" "${_Q_PSTATE}/${provider}.quota" 2>/dev/null || true
}

# quota_mark <provider> — the provider reported its quota is used up; skip it
# for QUINTET_QUOTA_TTL_SECS. Separate from the breaker (doesn't count as a failure).
quota_mark() {
    ensure_dir "$_Q_PSTATE"
    now_epoch > "${_Q_PSTATE}/$1.quota"
}

# quota_blocked <provider> -> 0 while a quota mark is younger than the TTL;
# prints the epoch it expires at.
quota_blocked() {
    local f="${_Q_PSTATE}/$1.quota" at
    [[ -f "$f" ]] || return 1
    at=$(cat "$f" 2>/dev/null); [[ "$at" =~ ^[0-9]+$ ]] || return 1
    at=$(( at + QUINTET_QUOTA_TTL_SECS ))
    (( $(now_epoch) < at )) || return 1
    echo "$at"
}

# circuit_open <provider> -> 0 if the breaker is currently open (provider should be skipped).
circuit_open() {
    local provider="$1"
    local cd="${_Q_PSTATE}/${provider}.cooldown"
    [[ -f "$cd" ]] || return 1
    local opened now; opened=$(cat "$cd" 2>/dev/null || echo 0); now=$(now_epoch)
    if (( now - opened >= QUINTET_CB_COOLDOWN_SECS )); then
        rm -f "$cd" 2>/dev/null || true   # cooldown elapsed -> half-open (allow a probe)
        return 1
    fi
    return 0
}

# pick_fallback <failed_provider> <candidate...> -> echoes first ready, breaker-closed candidate.
pick_fallback() {
    local failed="$1"; shift
    local c
    for c in "$@"; do
        [[ "$c" == "$failed" ]] && continue
        quintet_provider_ready "$c" || continue
        circuit_open "$c" && continue
        quota_blocked "$c" >/dev/null && continue
        echo "$c"; return 0
    done
    return 1
}
