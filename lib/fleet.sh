#!/usr/bin/env bash
# quintet/lib/fleet.sh — one-shot multi-AI fleet dispatch (claude-octopus style).
#
# Sends a single prompt to several provider CLIs in parallel (headless), applies
# the reliability layer (circuit breaker + fallback), and renders the collected
# answers. Modes:
#   parallel — fan out the same prompt, print each answer side by side.
#   consult  — alias of parallel (read-only advisory framing).
#   debate   — round 1 independent answers, then each provider critiques the others.
#   review   — frame the prompt as a code/diff review and aggregate findings.
# ─────────────────────────────────────────────────────────────────────────────

# Resolve a provider list. Accepts "all", a spec, or explicit names.
# Echoes ready providers (skips missing/unauthenticated/breaker-open), one per line.
_quintet_resolve_providers() {
    local arg="$1" p
    local -a candidates=()
    if [[ -z "$arg" || "$arg" == "all" ]]; then
        candidates=("${QUINTET_PROVIDERS[@]}")
    else
        # Comma or space separated; strip optional N: prefixes (fleet ignores counts).
        arg="${arg//,/ }"
        for p in $arg; do candidates+=( "${p##*:}" ); done
    fi
    for p in "${candidates[@]}"; do
        quintet_provider_validate "$p"
        if ! quintet_provider_ready "$p"; then
            log WARN "skipping $p (not installed or not authenticated)"; continue
        fi
        if circuit_open "$p"; then
            log WARN "skipping $p (circuit breaker open — cooling down)"; continue
        fi
        echo "$p"
    done
}

# Run one provider one-shot with reliability bookkeeping; write answer to file.
# Args: provider prompt out_file
_quintet_fleet_one() {
    local provider="$1" prompt="$2" out="$3"
    local resp code
    resp=$(quintet_provider_oneshot "$provider" "$prompt"); code=$?
    if [[ $code -ne 0 ]]; then
        local class; class=$(record_failure "$provider" "$code" "$resp")
        printf '%s' "$resp" > "$out"
        echo "$code:$class" > "${out}.status"
    else
        record_success "$provider"
        printf '%s' "$resp" > "$out"
        echo "0:ok" > "${out}.status"
    fi
}

# Fan out a prompt to a set of providers in parallel. Echoes a results dir path.
# Args: prompt provider-list-string
_quintet_fan_out() {
    local prompt="$1" provider_arg="$2"
    local -a providers=()
    mapfile -t providers < <(_quintet_resolve_providers "$provider_arg")
    [[ "${#providers[@]}" -ge 1 ]] || die "fleet: no ready providers (run: quintet doctor)"

    local rundir; rundir="$(mktemp -d "${TMPDIR:-/tmp}/quintet-fleet.XXXXXX")"
    local p
    for p in "${providers[@]}"; do
        log INFO "dispatching → $(quintet_provider_emoji "$p") $p"
        _quintet_fleet_one "$p" "$prompt" "${rundir}/${p}.out" &
    done
    wait

    # Apply fallback for any provider that failed transiently.
    for p in "${providers[@]}"; do
        local st; st=$(cat "${rundir}/${p}.out.status" 2>/dev/null || echo "1:transient")
        if [[ "$st" != 0:* ]]; then
            local fb; fb=$(pick_fallback "$p" "${QUINTET_PROVIDERS[@]}") || continue
            # don't double-run a provider we already used
            printf '%s\n' "${providers[@]}" | grep -qx "$fb" && continue
            log WARN "$p failed (${st#*:}); falling back → $fb"
            _quintet_fleet_one "$fb" "$prompt" "${rundir}/${p}__fallback_${fb}.out"
        fi
    done
    echo "$rundir"
}

_quintet_render_dir() {
    local rundir="$1" f provider st
    for f in "$rundir"/*.out; do
        [[ -e "$f" ]] || continue
        provider="$(basename "$f" .out)"
        st=$(cat "${f}.status" 2>/dev/null || echo "?")
        echo "════════════════════════════════════════════════════════════"
        echo "$(quintet_provider_emoji "${provider%%__*}") ${provider}   [${st}]"
        echo "════════════════════════════════════════════════════════════"
        cat "$f"; echo
    done
}

quintet_fleet_parallel() {
    local prompt="$1" providers="${2:-all}"
    [[ -n "$prompt" ]] || die "fleet: missing prompt"
    local rundir; rundir="$(_quintet_fan_out "$prompt" "$providers")"
    _quintet_render_dir "$rundir"
    rm -rf "$rundir" 2>/dev/null || true
}

quintet_fleet_review() {
    local target="$1" providers="${2:-all}"
    [[ -n "$target" ]] || die "fleet review: missing target (a diff, file path, or description)"
    local prompt
    prompt="You are performing a focused code review. Identify correctness bugs, security issues, and risky patterns. Be specific (file:line where possible) and rank findings by severity. Do not restate the code. Review target:

${target}"
    quintet_fleet_parallel "$prompt" "$providers"
}

# Two-round debate: independent answers, then cross-critique + refined position.
quintet_fleet_debate() {
    local question="$1" providers="${2:-all}"
    [[ -n "$question" ]] || die "fleet debate: missing question"

    log INFO "── debate round 1: independent positions ──"
    local r1; r1="$(_quintet_fan_out "$question" "$providers")"
    local round1_text; round1_text="$(_quintet_render_dir "$r1")"
    echo "$round1_text"

    log INFO "── debate round 2: cross-critique ──"
    local critique_prompt
    critique_prompt="Below are answers from multiple AI assistants to the question:

QUESTION: ${question}

ANSWERS:
${round1_text}

Critique the other answers, point out where they are wrong or incomplete, and give your refined final position. Be concise and concrete."
    local r2; r2="$(_quintet_fan_out "$critique_prompt" "$providers")"
    _quintet_render_dir "$r2"
    rm -rf "$r1" "$r2" 2>/dev/null || true

    echo
    echo "ℹ️  Synthesis is intentionally left to the orchestrating Claude: weigh the"
    echo "    round-2 positions above and state the consensus + remaining disagreements."
}
