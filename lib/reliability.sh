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

# classify_error <exit_code> <error_text> -> "transient" | "permanent"
classify_error() {
    local code="${1:-1}" text; text=$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')
    [[ "$code" == "124" ]] && { echo "transient"; return 0; }   # timeout(1) kill
    if printf '%s' "$text" | grep -qE '429|rate.?limit|too many requests|overloaded|capacity|temporarily|5[0-9]{2}|bad gateway|service unavailable|gateway timeout|timed out|timeout|connection refused|econnreset|econnrefused|etimedout|network'; then
        echo "transient"; return 0
    fi
    if printf '%s' "$text" | grep -qE '401|403|unauthorized|forbidden|invalid.?api.?key|authentication|billing|payment|quota exceeded|insufficient|404|not found|invalid model|400|bad request'; then
        echo "permanent"; return 0
    fi
    echo "transient"   # unknown -> safe to retry
}

# record_failure <provider> <exit_code> <error_text> -> echoes the error class.
record_failure() {
    local provider="$1" code="${2:-1}" text="${3:-}"
    ensure_dir "$_Q_PSTATE"
    local class; class=$(classify_error "$code" "$text")
    local ts; ts=$(now_epoch)
    local f="${_Q_PSTATE}/${provider}.failures"
    echo "${ts}:${class}:${code}" >> "$f"
    tail -20 "$f" > "${f}.tmp" 2>/dev/null && mv "${f}.tmp" "$f"
    if [[ "$class" == "transient" ]]; then
        local recent; recent=$(grep -c ":transient:" "$f" 2>/dev/null || echo 0)
        if [[ "$recent" -ge "$QUINTET_CB_FAILURE_THRESHOLD" ]]; then
            echo "$ts" > "${_Q_PSTATE}/${provider}.cooldown"
            log WARN "circuit breaker OPEN for $provider ($recent transient failures, cooling down ${QUINTET_CB_COOLDOWN_SECS}s)"
        fi
    fi
    echo "$class"
}

# record_success <provider> — clears failure state and any open breaker.
record_success() {
    local provider="$1"
    rm -f "${_Q_PSTATE}/${provider}.failures" "${_Q_PSTATE}/${provider}.cooldown" 2>/dev/null || true
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
        echo "$c"; return 0
    done
    return 1
}
