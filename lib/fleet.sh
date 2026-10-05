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
# An answer above this many bytes is cut and labeled 0:truncated.
QUINTET_MAX_ANSWER_BYTES="${QUINTET_MAX_ANSWER_BYTES:-2097152}"
[[ "$QUINTET_MAX_ANSWER_BYTES" =~ ^[0-9]+$ ]] || QUINTET_MAX_ANSWER_BYTES=2097152

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
# (status 0:*) or timed out with partial output (124:timeout, marked "(partial)"),
# ANSI-stripped and length-capped, labeled by provider. Safe to
# splice into a follow-up prompt — bounded well under the argv size limit.
_quintet_answers_block() {
    local rundir="$1" f provider st body tag
    for f in "$rundir"/*.out; do
        [[ -e "$f" ]] || continue
        provider="$(basename "$f" .out)"
        st=$(cat "${f}.status" 2>/dev/null || echo "?")
        case "$st" in 0:*) tag="" ;; 124:timeout) tag=" (partial)" ;; *) continue ;; esac
        body=$(_quintet_clean_answer "$(cat "$f")")
        [[ -n "${body//[[:space:]]/}" ]] || continue
        printf -- '--- %s%s ---\n%s\n\n' "$(_quintet_answer_label "$provider")" "$tag" "$body"
    done
}

# _quintet_time_left — seconds until QUINTET_DEADLINE_AT (a large number if unset).
_quintet_time_left() {
    if [[ "${QUINTET_DEADLINE_AT:-}" =~ ^[0-9]+$ ]]; then
        echo $(( QUINTET_DEADLINE_AT - $(now_epoch) ))
    else
        echo 999999
    fi
}

# _quintet_deadline_init <rounds> <provider...> — one wall-clock budget for the
# whole command: QUINTET_DEADLINE_SECS (or --deadline), else rounds × the slowest
# provider's timeout + 120 s. Exported as QUINTET_DEADLINE_AT (tmux workers get it
# via the env file). An already-set deadline (a debate's) is kept.
_quintet_deadline_init() {
    local rounds="$1" p t max_t=0 budget; shift
    [[ "${QUINTET_DEADLINE_AT:-}" =~ ^[0-9]+$ ]] && return 0
    budget="${QUINTET_DEADLINE_SECS:-}"
    if [[ -n "$budget" ]]; then
        [[ "$budget" =~ ^[0-9]+$ ]] || die "invalid deadline '$budget' (seconds)"
        budget=$(( 10#$budget ))
    else
        for p in "$@"; do
            t="$(quintet_provider_timeout "$p")"; [[ "$t" =~ ^[0-9]+$ ]] || t=240
            (( 10#$t > max_t )) && max_t=$(( 10#$t ))
        done
        budget=$(( rounds * max_t + 120 ))
    fi
    export QUINTET_DEADLINE_AT=$(( $(now_epoch) + budget ))
}

# _quintet_token_provider <token> — provider of a [N:]provider[:role[:model]]
# token ("gemini" -> "agy").
_quintet_token_provider() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+: ]] && p="${p#*:}"
    p="${p%%:*}"
    [[ "$p" == "gemini" ]] && p="agy"
    printf '%s' "$p"
}

# Resolve a provider list into the array named by <outvar>. Accepts "all", a spec,
# or explicit names. Keeps ready providers (skips missing/unauthenticated/
# breaker-open). Duplicates are dropped, first-seen order kept: a fleet runs one
# worker per provider (window names and .out files are per provider) (C-M2).
# Must run in the caller's shell so an unsupported-provider die() exits the
# command instead of a subshell.
# Args: outvar provider-list-string
_quintet_resolve_providers() {
    local -n _qrp_out="$1"
    local arg="$2" p p_clean
    local -a candidates=()
    local -A seen=()
    _qrp_out=()
    if [[ -z "$arg" || "$arg" == "all" ]]; then
        candidates=("${QUINTET_PROVIDERS[@]}")
    else
        # Comma or space separated tokens shaped [N:]provider[:role[:model]];
        # fleet ignores counts/roles/models. Embedded --flags are handled by
        # _quintet_fan_out, so skip them here.
        arg="${arg//,/ }"
        for p in $arg; do
            [[ "$p" == --* ]] && continue
            p_clean="$(_quintet_token_provider "$p")"
            if [[ -n "${seen[$p_clean]:-}" ]]; then
                log WARN "fleet: dropping duplicate provider entry '$p' (already have $p_clean)"
                continue
            fi
            seen[$p_clean]=1
            candidates+=( "$p_clean" )
        done
        [[ "${#candidates[@]}" -ge 1 ]] || candidates=("${QUINTET_PROVIDERS[@]}")
    fi
    for p in "${candidates[@]}"; do
        quintet_provider_validate "$p"
        if ! quintet_provider_ready "$p"; then
            log WARN "skipping $p (not installed or not authenticated)"; continue
        fi
        if circuit_open "$p"; then
            log WARN "skipping $p (circuit breaker open — cooling down)"; continue
        fi
        local q_until
        if q_until="$(quota_blocked "$p")"; then
            log WARN "skipping $p (out of quota; retry after $(date -d "@$q_until" +%H:%M 2>/dev/null || echo "$q_until"))"; continue
        fi
        _qrp_out+=( "$p" )
    done
}

# A bare --model/--effort is only unambiguous for a single-provider fleet
# (decision 3). Bind it to that provider as a map entry so a fallback provider
# never inherits it; with more than one distinct requested provider, die.
# Args: provider-list-string resolved-provider...
_quintet_bind_bare_cli() {
    local arg="$1" kind bare_var map_var flag n=0 p
    local -A seen=()
    shift
    if [[ -z "$arg" || "$arg" == "all" ]]; then
        n=${#QUINTET_PROVIDERS[@]}
    else
        for p in ${arg//,/ }; do
            [[ "$p" == --* ]] && continue
            p="$(_quintet_token_provider "$p")"
            [[ -n "${seen[$p]:-}" ]] && continue
            seen[$p]=1; n=$((n+1))
        done
    fi
    for kind in MODEL EFFORT; do
        bare_var="QUINTET_${kind}_CLI"; map_var="QUINTET_${kind}_MAP"
        [[ -n "${!bare_var:-}" ]] || continue
        flag="--$(printf '%s' "$kind" | tr '[:upper:]' '[:lower:]')"
        [[ $n -eq 1 && $# -eq 1 ]] \
            || die "fleet: bare $flag is ambiguous with more than one provider; use $flag provider=value[,provider=value]"
        export "${map_var}=${!map_var:+${!map_var},}$1=${!bare_var}"
        unset "$bare_var"
    done
}

# Resolve every provider's model/effort once in the caller's shell, so a bad
# env-sourced value (QUINTET_<P>_MODEL, QUINTET_EFFORT, QUINTET_MODEL_MAP, …)
# dies here, before any worker launches (S-L4, R-L1). Args: provider...
_quintet_check_fleet_values() {
    local p
    for p in "$@"; do
        quintet_resolve_model "$p" "${QUINTET_MODEL_MAP:-}" "" "${QUINTET_MODEL_CLI:-}" >/dev/null
        quintet_resolve_effort "$p" "${QUINTET_EFFORT_MAP:-}" "${QUINTET_EFFORT_CLI:-}" >/dev/null
    done
}

# Run one provider one-shot with reliability bookkeeping; write answer to file.
# Args: provider prompt out_file [no_mcp] [tee_to]
_quintet_fleet_one() {
    local provider="$1" prompt="$2" out="$3"
    local no_mcp="${4:-${QUINTET_NO_MCP:-false}}" tee_to="${5:-}"
    local resp code start end secs
    start=$(now_epoch)
    # The one-shot's stderr temp file goes in the run dir (dynamic scope), so an
    # aborted fleet's rundir cleanup removes it too (C-L1).
    local _q_errdir; _q_errdir="$(dirname -- "$out")"
    # stderr goes to <seat>.err, not into the answer; render shows it for a failed seat.
    local errf="${out%.out}.err"
    resp=$(quintet_provider_oneshot "$provider" "$prompt" "$no_mcp" "" "" "" "$tee_to" "$errf"); code=$?
    end=$(now_epoch); secs=$(( end - start ))
    local errtext label=""; errtext="$(cat -- "$errf" 2>/dev/null)"
    # Exit 0 with nothing to show is a failed answer (transient: the fallback runs).
    if [[ $code -eq 0 && -z "${resp//[[:space:]]/}" ]]; then
        code=1; label="empty"
    fi
    printf '%s' "$resp" > "$out"
    if [[ $code -ne 0 ]]; then
        # Quota is tracked by its TTL mark only, not the breaker (decision 7).
        local class=""
        [[ $code -eq 125 ]] || class=$(record_failure "$provider" "$code" "$resp" "$errtext")
        if [[ -z "$label" ]]; then
            if [[ $code -eq 125 ]]; then
                label="quota"; quota_mark "$provider"
            elif grep -Eqi 'quintet: prompt too large|prompt is too long|context length' <<< "$errtext"; then
                label="too-large"
            elif [[ $code -eq 124 ]]; then
                label="timeout"
            else
                label="$class"
            fi
        fi
        echo "$code:$label" > "${out}.status"
        # Live completion line so the run doesn't go dark while it works.
        log WARN "✗ $(quintet_provider_emoji "$provider") $provider failed [${code}:${label}] after ${secs}s"
    else
        record_success "$provider"
        label="ok"
        if (( $(wc -c < "$out") > QUINTET_MAX_ANSWER_BYTES )); then
            head -c "$QUINTET_MAX_ANSWER_BYTES" "$out" > "${out}.tmp" && mv -- "${out}.tmp" "$out"
            label="truncated"
        fi
        echo "0:$label" > "${out}.status"
        log INFO "✓ $(quintet_provider_emoji "$provider") $provider answered in ${secs}s"
    fi
}

# Internal worker entry point invoked inside tmux windows. The provider's stdout
# is also streamed to the pane (stderr = the pane's tty) so attaching shows it (A5).
quintet_fleet_worker() {
    local provider="$1" prompt_file="$2" out_file="$3"
    local no_mcp="${4:-${QUINTET_NO_MCP:-false}}"
    [[ -f "$prompt_file" ]] || die "fleet worker: missing prompt file '$prompt_file'"
    local prompt
    prompt="$(cat "$prompt_file")"
    _quintet_fleet_one "$provider" "$prompt" "$out_file" "$no_mcp" /dev/stderr
}

_quintet_fan_out_tmux() {
    local prompt="$1" rundir="$2" no_mcp="${3:-false}"
    shift 3
    local -a providers=("$@")

    local prompt_file="${rundir}/prompt.txt"
    printf '%s' "$prompt" > "$prompt_file"

    # tmux format-expands -c; a $PWD with "#[" can't be escaped, so use the
    # direct path (the caller falls back when this returns 1).
    local cwd_esc
    cwd_esc="$(quintet_tmux_fmt_escape "$PWD")" || { log WARN "fleet: \$PWD contains '#[', which tmux can't use literally"; return 1; }
    local sess; sess="quintet-fleet-$(now_epoch)-$$-${RANDOM}"
    if ! qtmux new-session -d -s "$sess" -c "$cwd_esc" -n "leader" 2>/dev/null; then
        return 1
    fi
    # This runs inside the caller's $(...), so the traps live in that subshell.
    # On abort: kill the session (workers die with it) and remove the run dir
    # (env files, prompt, one-shot stderr files) (A4/A13, M3, C-L1). Before
    # returning, the traps are reset; a parent's traps are saved and restored
    # only when not in a subshell (in a subshell, trap -p shows the parent's
    # traps, and eval-ing them would run the parent's EXIT trap twice, C-L2).
    local prev_traps=""
    [[ "$BASH_SUBSHELL" -eq 0 ]] && prev_traps="$(trap -p EXIT INT TERM)"
    local cleanup
    cleanup="qtmux kill-session -t $(printf '%q' "=$sess") 2>/dev/null; rm -rf -- $(printf '%q' "$rundir")"
    # shellcheck disable=SC2064  # expand sess/rundir now
    trap "$cleanup" EXIT
    # shellcheck disable=SC2064
    trap "$cleanup; exit 130" INT TERM

    log INFO "Fleet session active. View live with: tmux attach -t $sess"
    printf "Tmux session: tmux attach -t %s\n" "$sess" >&2
    qtmux send-keys -t "=${sess}:=leader" "printf 'quintet fleet session %s\nProviders: %s\n' '$sess' '${providers[*]}'" Enter

    # Each window starts on a placeholder so remain-on-exit (a window option) is
    # set before the worker runs; respawn-pane -k then swaps in the worker. A
    # worker that crashes at once keeps its pane (dead) for inspection (A5, A6).
    local p out envf
    for p in "${providers[@]}"; do
        log INFO "dispatching (tmux) → $(quintet_provider_emoji "$p") $p"
        out="${rundir}/${p}.out"
        envf="${rundir}/${p}.env"
        quintet_write_worker_env "$p" "$envf" || { log ERROR "fleet: cannot write env file for $p"; continue; }
        qtmux new-window -d -t "=$sess" -n "$p" -c "$cwd_esc" sleep 86400 \
            && qtmux set-option -w -t "=${sess}:=${p}" remain-on-exit on >/dev/null \
            || { log ERROR "fleet: cannot create tmux window for $p"; continue; }
        # env -i: the worker sees only the env file and the pane's own
        # TERM/TMUX/TMUX_PANE, not the tmux server's global environment (S-M1, R-M1).
        # shellcheck disable=SC2016  # $1/$@ expand in the worker's bash
        qtmux respawn-pane -k -t "=${sess}:=${p}" -c "$cwd_esc" \
            "${QUINTET_PANE_ENV_I[@]}" "${BASH:-bash}" --noprofile --norc -c '. "$1" || { echo "quintet: cannot read worker env file" >&2; exit 1; }; rm -f -- "$1"; shift; exec "$@"' \
            quintet-worker "$envf" "${QUINTET_ROOT}/bin/quintet" __fleet_worker "$p" "$prompt_file" "$out" "$no_mcp" \
            || { log ERROR "fleet: cannot start worker for $p"; qtmux kill-window -t "=${sess}:=${p}" 2>/dev/null; }
    done

    # Poll for .status files. Deadline = slowest provider's own timeout + 30s
    # grace, so a QUINTET_<P>_TIMEOUT above QUINTET_TIMEOUT isn't cut short (A6).
    # A window whose pane is dead (or gone) without a .status is finished early.
    local max_t=0 t
    for p in "${providers[@]}"; do
        t="$(quintet_provider_timeout "$p")"
        [[ "$t" =~ ^[0-9]+$ ]] || t=240
        (( 10#$t > max_t )) && max_t=$((10#$t))
    done
    local deadline=$(( $(now_epoch) + max_t + 30 )) g="${QUINTET_KILL_GRACE:-10}"
    # The command's deadline caps it too (workers stop at it, plus kill grace).
    [[ "$g" =~ ^[0-9]+$ ]] || g=10
    if [[ "${QUINTET_DEADLINE_AT:-}" =~ ^[0-9]+$ ]] && (( QUINTET_DEADLINE_AT + 10#$g + 5 < deadline )); then
        deadline=$(( QUINTET_DEADLINE_AT + 10#$g + 5 ))
    fi
    # A tmux error (liveness unknown) keeps polling until the deadline.
    local all_done lv
    while :; do
        all_done=true
        for p in "${providers[@]}"; do
            [[ -f "${rundir}/${p}.out.status" ]] && continue
            lv="$(quintet_tmux_liveness "=${sess}:=${p}")"
            if [[ ( "$lv" == dead || "$lv" == gone ) && ! -f "${rundir}/${p}.out.status" ]]; then
                {
                    echo "fleet worker exited without a result. Last pane output:"
                    qtmux capture-pane -p -t "=${sess}:=${p}" -S -20 2>/dev/null
                } >> "${rundir}/${p}.out"
                echo "1:worker-crashed" > "${rundir}/${p}.out.status"
                log WARN "✗ $(quintet_provider_emoji "$p") $p worker exited without a result"
                continue
            fi
            all_done=false
        done
        [[ "$all_done" == "true" ]] && break
        (( $(now_epoch) >= deadline )) && break
        sleep 0.5
    done

    for p in "${providers[@]}"; do
        if [[ ! -f "${rundir}/${p}.out.status" ]]; then
            echo "Execution timed out in tmux window" >> "${rundir}/${p}.out"
            record_failure "$p" 124 "fleet tmux poll timeout" >/dev/null
            echo "124:timeout" > "${rundir}/${p}.out.status"
            log WARN "✗ $(quintet_provider_emoji "$p") $p timed out in tmux"
        fi
    done

    rm -f -- "$rundir"/*.env
    trap - EXIT INT TERM
    [[ -n "$prev_traps" ]] && eval "$prev_traps"
    if [[ "${QUINTET_FLEET_KEEP_SESSION:-false}" == "true" ]]; then
        log INFO "fleet session kept: tmux attach -t $sess   (remove: tmux kill-session -t '=$sess')"
    else
        qtmux kill-session -t "=$sess" 2>/dev/null || true
    fi
    return 0
}

# _quintet_kill_tree <pid> — kill <pid> and its descendants.
_quintet_kill_tree() {
    local c
    for c in $(pgrep -P "$1" 2>/dev/null); do _quintet_kill_tree "$c"; done
    kill "$1" 2>/dev/null
}

# _quintet_kill_jobs — kill this shell's background jobs and their descendants
# (the provider CLI runs a level or two below each job), then reap them.
_quintet_kill_jobs() {
    local j
    for j in $(jobs -p); do _quintet_kill_tree "$j"; done
    wait 2>/dev/null
}

# Fan out a prompt to a set of providers in parallel. Echoes a results dir path.
# Providers are resolved by the caller (in its own shell, so errors exit nonzero);
# provider-list-string is only scanned for embedded --flags.
# Args: prompt provider-list-string provider...
_quintet_fan_out() {
    local prompt="$1" provider_arg="$2"
    shift 2
    local -a providers=("$@")
    local use_tmux=true

    local no_mcp="${QUINTET_NO_MCP:-false}"
    if [[ "$provider_arg" == *--no-mcp* ]]; then
        no_mcp=true
        provider_arg="${provider_arg//--no-mcp/}"
    fi

    # --safe reaches launch/one-shot builders through QUINTET_SAFE_MODE.
    if [[ "$provider_arg" == *--safe* ]]; then
        export QUINTET_SAFE_MODE=true
        provider_arg="${provider_arg//--safe/}"
    fi

    # Check env var toggle
    if [[ "${QUINTET_FLEET_TMUX:-true}" == "false" || "${QUINTET_FLEET_TMUX:-true}" == "0" ]]; then
        use_tmux=false
    fi

    # Check provider_arg for --no-tmux or --tmux
    if [[ "$provider_arg" == *--no-tmux* ]]; then
        use_tmux=false
        provider_arg="${provider_arg//--no-tmux/}"
    fi
    if [[ "$provider_arg" == *--tmux* ]]; then
        use_tmux=true
        provider_arg="${provider_arg//--tmux/}"
    fi
    provider_arg="$(printf '%s' "$provider_arg" | xargs)"

    if ! quintet_tmux_available; then
        use_tmux=false
    fi

    # Every fleet dispatch is advisory/read-only — frame it so providers answer
    # instead of exploring the repo (the timeout culprit). One choke point covers
    # consult, debate, and review.
    if [[ -n "$QUINTET_ADVISORY_PREAMBLE" ]]; then
        prompt="${QUINTET_ADVISORY_PREAMBLE}

${prompt}"
    fi
    [[ "${#providers[@]}" -ge 1 ]] || die "fleet: no ready providers (run: quintet doctor)"

    local rundir; rundir="$(mktemp -d "${TMPDIR:-/tmp}/quintet-fleet.XXXXXX")" \
        || die "fleet: cannot create run dir"
    local p
    local ran_tmux=false

    if [[ "$use_tmux" == "true" ]]; then
        if _quintet_fan_out_tmux "$prompt" "$rundir" "$no_mcp" "${providers[@]}"; then
            ran_tmux=true
        else
            log WARN "failed to initialize tmux fleet session; falling back to direct background subshells"
        fi
    fi

    if [[ "$ran_tmux" == "false" ]]; then
        # On INT/TERM kill the one-shot subshells (and the CLIs under them) and
        # remove the run dir, which also holds their env dirs and errfiles
        # (_q_errdir). A normal exit keeps the run dir for the caller to render.
        # Prior traps are restored only outside a subshell, as in the tmux path (C-L2).
        local prev_traps="" cleanup
        [[ "$BASH_SUBSHELL" -eq 0 ]] && prev_traps="$(trap -p EXIT INT TERM)"
        cleanup="_quintet_kill_jobs; rm -rf -- $(printf '%q' "$rundir")"
        # shellcheck disable=SC2064  # expand rundir now
        trap "$cleanup" EXIT
        # shellcheck disable=SC2064
        trap "$cleanup; exit 130" INT TERM
        for p in "${providers[@]}"; do
            log INFO "dispatching → $(quintet_provider_emoji "$p") $p"
            _quintet_fleet_one "$p" "$prompt" "${rundir}/${p}.out" "$no_mcp" &
        done
        wait
        trap - EXIT INT TERM
        [[ -n "$prev_traps" ]] && eval "$prev_traps"
    fi

    # Apply fallback for any provider that failed transiently.
    for p in "${providers[@]}"; do
        local st; st=$(cat "${rundir}/${p}.out.status" 2>/dev/null || echo "1:transient")
        if [[ "$st" != 0:* ]]; then
            local fb left; fb=$(pick_fallback "$p" "${QUINTET_PROVIDERS[@]}") || continue
            # don't double-run a provider we already used
            printf '%s\n' "${providers[@]}" | grep -qx "$fb" && continue
            left="$(_quintet_time_left)"
            if (( left < 20 )); then
                log WARN "$p failed (${st#*:}); skipping fallback → $fb (${left}s left before the deadline)"
                continue
            fi
            log WARN "$p failed (${st#*:}); falling back → $fb"
            _quintet_fleet_one "$fb" "$prompt" "${rundir}/${p}__fallback_${fb}.out" "$no_mcp"
        fi
    done
    echo "$rundir"
}

_quintet_render_dir() {
    local rundir="$1" f provider st body partial
    for f in "$rundir"/*.out; do
        [[ -e "$f" ]] || continue
        provider="$(basename "$f" .out)"
        st=$(cat "${f}.status" 2>/dev/null || echo "?")
        echo "════════════════════════════════════════════════════════════"
        partial=""
        [[ "$st" == 124:timeout && -n "$(tr -d '[:space:]' < "$f" 2>/dev/null | head -c 1)" ]] && partial=" (partial)"
        echo "$(quintet_provider_emoji "${provider##*__fallback_}") $(_quintet_answer_label "$provider")   [${st}]${partial}"
        echo "════════════════════════════════════════════════════════════"
        if [[ "$st" == 0:* || -n "$partial" ]]; then
            cat "$f"
            [[ -n "$partial" ]] && echo "[partial: timed out before finishing]"
        else
            # Failed providers often dump hundreds of lines of CLI noise — trim it
            # so it doesn't bury the real answers.
            _quintet_clean_answer "$(cat "$f"; [[ -s "${f%.out}.err" ]] && { printf '\n[stderr]\n'; cat "${f%.out}.err"; })" "$QUINTET_FAIL_RENDER_CAP"
        fi
        echo
    done
}

quintet_fleet_parallel() {
    local prompt="" prov_arg=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-tmux) export QUINTET_FLEET_TMUX=false; shift ;;
            --tmux)    export QUINTET_FLEET_TMUX=true; shift ;;
            --no-mcp)  export QUINTET_NO_MCP=true; shift ;;
            --safe)    export QUINTET_SAFE_MODE=true; shift ;;
            --model)   need_arg "$1" $#; quintet_parse_cli_value --model "$2" QUINTET_MODEL_MAP QUINTET_MODEL_CLI
                       export QUINTET_MODEL_MAP QUINTET_MODEL_CLI; shift 2 ;;
            --effort)  need_arg "$1" $#; quintet_parse_cli_value --effort "$2" QUINTET_EFFORT_MAP QUINTET_EFFORT_CLI
                       export QUINTET_EFFORT_MAP QUINTET_EFFORT_CLI; shift 2 ;;
            --deadline) need_arg "$1" $#; export QUINTET_DEADLINE_SECS="$2"; shift 2 ;;
            *)
                if [[ -z "$prompt" ]]; then
                    prompt="$1"
                elif [[ -z "$prov_arg" ]]; then
                    prov_arg="$1"
                fi
                shift ;;
        esac
    done
    [[ -n "$prov_arg" ]] || prov_arg="all"
    # "-" reads the prompt from stdin (prompts too long for an argument).
    [[ "$prompt" == "-" ]] && prompt="$(cat)"
    [[ -n "$prompt" ]] || die "fleet: missing prompt"
    local -a plist=()
    _quintet_resolve_providers plist "$prov_arg"
    [[ "${#plist[@]}" -ge 1 ]] || die "fleet: no ready providers (run: quintet doctor)"
    _quintet_bind_bare_cli "$prov_arg" "${plist[@]}"
    _quintet_check_fleet_values "${plist[@]}"
    _quintet_deadline_init 1 "${plist[@]}"
    local rundir
    rundir="$(_quintet_fan_out "$prompt" "$prov_arg" "${plist[@]}")" || return 1
    [[ -d "$rundir" ]] || return 1
    _quintet_render_dir "$rundir"
    rm -rf "$rundir" 2>/dev/null || true
}

quintet_fleet_review() {
    local target="" prov_arg=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-tmux) export QUINTET_FLEET_TMUX=false; shift ;;
            --tmux)    export QUINTET_FLEET_TMUX=true; shift ;;
            --no-mcp)  export QUINTET_NO_MCP=true; shift ;;
            --safe)    export QUINTET_SAFE_MODE=true; shift ;;
            --model)   need_arg "$1" $#; quintet_parse_cli_value --model "$2" QUINTET_MODEL_MAP QUINTET_MODEL_CLI
                       export QUINTET_MODEL_MAP QUINTET_MODEL_CLI; shift 2 ;;
            --effort)  need_arg "$1" $#; quintet_parse_cli_value --effort "$2" QUINTET_EFFORT_MAP QUINTET_EFFORT_CLI
                       export QUINTET_EFFORT_MAP QUINTET_EFFORT_CLI; shift 2 ;;
            --deadline) need_arg "$1" $#; export QUINTET_DEADLINE_SECS="$2"; shift 2 ;;
            *)
                if [[ -z "$target" ]]; then
                    target="$1"
                elif [[ -z "$prov_arg" ]]; then
                    prov_arg="$1"
                fi
                shift ;;
        esac
    done
    [[ -n "$prov_arg" ]] || prov_arg="all"
    [[ "$target" == "-" ]] && target="$(cat)"
    [[ -n "$target" ]] || die "fleet review: missing target (a diff, file path, or description)"
    local prompt
    prompt="You are performing a focused code review. Identify correctness bugs, security issues, and risky patterns. Be specific (file:line where possible) and rank findings by severity. Do not restate the code. Review target:

${target}"
    quintet_fleet_parallel "$prompt" "$prov_arg"
}

# Two-round debate: independent answers, then cross-critique + refined position.
# Both rounds are streamed (per-provider completion logs) and the full transcript
# is persisted under $QUINTET_HOME/debates/<ts>/ so the raw arguments survive — not
# just whatever the orchestrator chooses to summarize.
quintet_fleet_debate() {
    local question="" prov_arg=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-tmux) export QUINTET_FLEET_TMUX=false; shift ;;
            --tmux)    export QUINTET_FLEET_TMUX=true; shift ;;
            --no-mcp)  export QUINTET_NO_MCP=true; shift ;;
            --safe)    export QUINTET_SAFE_MODE=true; shift ;;
            --model)   need_arg "$1" $#; quintet_parse_cli_value --model "$2" QUINTET_MODEL_MAP QUINTET_MODEL_CLI
                       export QUINTET_MODEL_MAP QUINTET_MODEL_CLI; shift 2 ;;
            --effort)  need_arg "$1" $#; quintet_parse_cli_value --effort "$2" QUINTET_EFFORT_MAP QUINTET_EFFORT_CLI
                       export QUINTET_EFFORT_MAP QUINTET_EFFORT_CLI; shift 2 ;;
            --deadline) need_arg "$1" $#; export QUINTET_DEADLINE_SECS="$2"; shift 2 ;;
            *)
                if [[ -z "$question" ]]; then
                    question="$1"
                elif [[ -z "$prov_arg" ]]; then
                    prov_arg="$1"
                fi
                shift ;;
        esac
    done
    [[ -n "$prov_arg" ]] || prov_arg="all"
    [[ "$question" == "-" ]] && question="$(cat)"
    [[ -n "$question" ]] || die "fleet debate: missing question"

    # Seconds-resolution ts alone can collide if two debates start in the same
    # second under the same QUINTET_HOME — mktemp -d guarantees a unique dir so
    # transcripts never clobber each other.
    local ts base archive; ts="$(now_epoch)"
    base="${QUINTET_HOME:-$HOME/.quintet}/debates"
    ensure_dir "$base"
    archive="$(mktemp -d "${base}/${ts}.XXXXXX")" || die "fleet debate: cannot create transcript dir under ${base}"

    local -a plist=()
    _quintet_resolve_providers plist "$prov_arg"
    [[ "${#plist[@]}" -ge 1 ]] || die "fleet debate: no ready providers (run: quintet doctor)"
    _quintet_bind_bare_cli "$prov_arg" "${plist[@]}"
    _quintet_check_fleet_values "${plist[@]}"
    _quintet_deadline_init 2 "${plist[@]}"

    log INFO "── debate round 1: independent positions ──"
    local r1
    r1="$(_quintet_fan_out "$question" "$prov_arg" "${plist[@]}")" || return 1
    [[ -d "$r1" ]] || return 1
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

    local left; left="$(_quintet_time_left)"
    if (( left < 20 )); then
        log WARN "skipping debate round 2 (${left}s left before the deadline)"
        rm -rf "$r1" 2>/dev/null || true
        echo
        echo "📁 Debate transcript (round 1 only): ${archive}/round1.md"
        return 0
    fi

    log INFO "── debate round 2: cross-critique ──"
    local critique_prompt
    critique_prompt="Below are independent answers from several AI assistants to a question.

QUESTION: ${question}

ANSWERS:
${answers}

Critique the other answers — name specifically where they are wrong or incomplete — then give your refined final position. Be concise and concrete. Do not restate the question."
    # Re-resolve: round-1 failures may have opened a circuit breaker.
    _quintet_resolve_providers plist "$prov_arg"
    [[ "${#plist[@]}" -ge 1 ]] || { rm -rf "$r1"; die "fleet debate: no ready providers for round 2"; }
    local r2
    r2="$(_quintet_fan_out "$critique_prompt" "$prov_arg" "${plist[@]}")" || { rm -rf "$r1"; return 1; }
    [[ -d "$r2" ]] || { rm -rf "$r1"; return 1; }
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
