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

# Advisory framing prepended to every fleet prompt. Fleet is read-only and
# one-shot, so we explicitly stop providers from wandering into agentic file
# exploration / tool use — that exploration was the main cause of exit-124
# timeouts (a cold CLI would spend the whole budget reading the repo instead of
# answering). Override or disable via QUINTET_ADVISORY_PREAMBLE.
# Note: `-` (not `:-`) so an explicitly empty QUINTET_ADVISORY_PREAMBLE= disables
# the preamble (the documented opt-out); only an *unset* var gets the default.
QUINTET_ADVISORY_PREAMBLE="${QUINTET_ADVISORY_PREAMBLE-IMPORTANT: This is a one-shot advisory question, not a coding session. Do NOT read, list, or explore files. Do NOT run shell commands or invoke tools. Answer directly, from reasoning, as concise plain text.}"

# Max characters of any single answer we fold back into a follow-up prompt
# (debate round 2). Keeps the assembled prompt well under the 128KB single-argv
# limit (MAX_ARG_STRLEN) that produced exit-126 failures when a provider's
# verbose error output was spliced into the next round's command line.
QUINTET_ANSWER_CAP="${QUINTET_ANSWER_CAP:-8000}"
# Cap applied when *displaying* a failed provider's output, so a multi-hundred-line
# error dump doesn't bury the readable answers.
QUINTET_FAIL_RENDER_CAP="${QUINTET_FAIL_RENDER_CAP:-1500}"

# Strip ANSI escapes and cap length. Used before re-injecting an answer into a
# follow-up prompt and before rendering noisy failure output.
_quintet_clean_answer() {
    local text="$1" cap="${2:-$QUINTET_ANSWER_CAP}"
    # `\x1b` in a sed pattern is a GNU extension; BSD sed (macOS default) doesn't
    # honor it. Use an ANSI-C-quoted literal ESC so the strip works on both.
    local esc=$'\e'
    text=$(printf '%s' "$text" | sed -E "s/${esc}\\[[0-9;]*[a-zA-Z]//g")
    local n=${#text}
    if (( n > cap )); then
        text="${text:0:cap}
…[truncated ${n}→${cap} chars]"
    fi
    printf '%s' "$text"
}

# Map a run-file basename to the provider that actually produced the answer.
# Normal files are "<provider>.out". Fallback files are "<orig>__fallback_<real>.out";
# the answer came from <real>, so attribute it there (noting it stood in for <orig>)
# rather than mislabeling it as <orig>.
_quintet_answer_label() {
    local base="$1"
    if [[ "$base" == *__fallback_* ]]; then
        printf '%s (fallback for %s)' "${base##*__fallback_}" "${base%%__fallback_*}"
    else
        printf '%s' "$base"
    fi
}

# Build a clean "ANSWERS" block from a fan-out dir: only providers that succeeded
# (status 0:ok), ANSI-stripped and length-capped, labeled by provider. Safe to
# splice into a follow-up prompt — bounded well under the argv size limit.
_quintet_answers_block() {
    local rundir="$1" f provider st body
    for f in "$rundir"/*.out; do
        [[ -e "$f" ]] || continue
        provider="$(basename "$f" .out)"
        st=$(cat "${f}.status" 2>/dev/null || echo "?")
        [[ "$st" == 0:* ]] || continue
        body=$(_quintet_clean_answer "$(cat "$f")")
        [[ -n "${body//[[:space:]]/}" ]] || continue
        printf -- '--- %s ---\n%s\n\n' "$(_quintet_answer_label "$provider")" "$body"
    done
}

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
    local resp code start end secs
    start=$(now_epoch)
    resp=$(quintet_provider_oneshot "$provider" "$prompt"); code=$?
    end=$(now_epoch); secs=$(( end - start ))
    if [[ $code -ne 0 ]]; then
        local class; class=$(record_failure "$provider" "$code" "$resp")
        printf '%s' "$resp" > "$out"
        echo "$code:$class" > "${out}.status"
        # Live completion line so the run doesn't go dark while it works.
        log WARN "✗ $(quintet_provider_emoji "$provider") $provider failed [${code}:${class}] after ${secs}s"
    else
        record_success "$provider"
        printf '%s' "$resp" > "$out"
        echo "0:ok" > "${out}.status"
        log INFO "✓ $(quintet_provider_emoji "$provider") $provider answered in ${secs}s"
    fi
}

# Fan out a prompt to a set of providers in parallel. Echoes a results dir path.
# Args: prompt provider-list-string
_quintet_fan_out() {
    local prompt="$1" provider_arg="$2"
    # Every fleet dispatch is advisory/read-only — frame it so providers answer
    # instead of exploring the repo (the timeout culprit). One choke point covers
    # consult, debate, and review.
    if [[ -n "$QUINTET_ADVISORY_PREAMBLE" ]]; then
        prompt="${QUINTET_ADVISORY_PREAMBLE}

${prompt}"
    fi
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
    local rundir="$1" f provider st body
    for f in "$rundir"/*.out; do
        [[ -e "$f" ]] || continue
        provider="$(basename "$f" .out)"
        st=$(cat "${f}.status" 2>/dev/null || echo "?")
        echo "════════════════════════════════════════════════════════════"
        echo "$(quintet_provider_emoji "${provider%%__*}") ${provider}   [${st}]"
        echo "════════════════════════════════════════════════════════════"
        if [[ "$st" == 0:* ]]; then
            cat "$f"
        else
            # Failed providers often dump hundreds of lines of CLI noise — trim it
            # so it doesn't bury the real answers.
            _quintet_clean_answer "$(cat "$f")" "$QUINTET_FAIL_RENDER_CAP"
        fi
        echo
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
# Both rounds are streamed (per-provider completion logs) and the full transcript
# is persisted under $QUINTET_HOME/debates/<ts>/ so the raw arguments survive — not
# just whatever the orchestrator chooses to summarize.
quintet_fleet_debate() {
    local question="$1" providers="${2:-all}"
    [[ -n "$question" ]] || die "fleet debate: missing question"

    # Seconds-resolution ts alone can collide if two debates start in the same
    # second under the same QUINTET_HOME — mktemp -d guarantees a unique dir so
    # transcripts never clobber each other.
    local ts base archive; ts="$(now_epoch)"
    base="${QUINTET_HOME:-$HOME/.quintet}/debates"
    ensure_dir "$base"
    archive="$(mktemp -d "${base}/${ts}.XXXXXX")" || die "fleet debate: cannot create transcript dir under ${base}"

    log INFO "── debate round 1: independent positions ──"
    local r1; r1="$(_quintet_fan_out "$question" "$providers")"
    local round1_text; round1_text="$(_quintet_render_dir "$r1")"
    echo "$round1_text"
    printf '%s\n' "$round1_text" > "${archive}/round1.md"

    # Round 2 sees ONLY the clean, length-capped successful answers — never the
    # box-art, status tags, or multi-hundred-line failure dumps. That assembled
    # block is what previously blew past the 128KB argv limit (exit 126).
    local answers; answers="$(_quintet_answers_block "$r1")"
    if [[ -z "${answers//[[:space:]]/}" ]]; then
        log WARN "no provider produced a usable round-1 answer — skipping round 2"
        rm -rf "$r1" 2>/dev/null || true
        echo
        echo "📁 Debate transcript: ${archive}/round1.md"
        # All providers failed round 1 — signal failure so orchestrators don't
        # treat an empty debate as a successful run.
        return 1
    fi

    log INFO "── debate round 2: cross-critique ──"
    local critique_prompt
    critique_prompt="Below are independent answers from several AI assistants to a question.

QUESTION: ${question}

ANSWERS:
${answers}

Critique the other answers — name specifically where they are wrong or incomplete — then give your refined final position. Be concise and concrete. Do not restate the question."
    local r2; r2="$(_quintet_fan_out "$critique_prompt" "$providers")"
    local round2_text; round2_text="$(_quintet_render_dir "$r2")"
    echo "$round2_text"
    printf '%s\n' "$round2_text" > "${archive}/round2.md"

    # Persist a combined transcript the user / orchestrator can reopen verbatim.
    {
        echo "# Quintet debate"
        echo
        echo "**Question:** ${question}"
        echo "**When:** $(now_iso)"
        echo
        echo "## Round 1 — independent positions"
        echo
        cat "${archive}/round1.md"
        echo
        echo "## Round 2 — cross-critique"
        echo
        cat "${archive}/round2.md"
    } > "${archive}/transcript.md"

    rm -rf "$r1" "$r2" 2>/dev/null || true

    echo
    echo "📁 Full debate transcript: ${archive}/transcript.md"
    echo "ℹ️  Synthesis is left to the orchestrating Claude: weigh the round-2 positions"
    echo "    above, state the consensus + remaining disagreements, and show each model's"
    echo "    key argument so the user can see the debate — not just the conclusion."
}
