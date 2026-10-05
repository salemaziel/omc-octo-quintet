#!/usr/bin/env bash
# quintet/lib/team.sh — persistent tmux worker-team runtime (omc-teams style),
# extended to all six providers (claude, codex, agy, copilot, qwen, opencode).
#
# A "team" is a detached tmux session of long-lived worker windows. Each worker
# is an interactive agent CLI that receives a task via send-keys and then works
# autonomously in the shared working directory. Coordination is file-based: a
# team manifest plus a shared task board the orchestrating Claude can read/write.
# ─────────────────────────────────────────────────────────────────────────────

if ! declare -f quintet_role_exists >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "${QUINTET_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/roles.sh"
fi

_quintet_team_dir() { echo "${QUINTET_STATE_DIR}/teams/$1"; }

# Parse a team spec like "2:claude,1:qwen,1:copilot" or "1:codex:implementer,1:agy:stock"
# into a flat worker list. Echoes "provider:role" per line. Validates each.
_quintet_parse_spec() {
    local spec="$1" tok n provider role model i
    local -a _toks=() parts=()
    IFS=',' read -ra _toks <<< "$spec"
    for tok in "${_toks[@]}"; do
        tok="${tok// /}"
        [[ -z "$tok" ]] && continue
        IFS=':' read -ra parts <<< "$tok"
        role="stock"
        model=""
        if [[ "${#parts[@]}" -eq 1 ]]; then
            n=1
            provider="${parts[0]}"
        elif [[ "${#parts[@]}" -eq 2 ]]; then
            if [[ "${parts[0]}" =~ ^[0-9]+$ ]]; then
                n="${parts[0]}"
                provider="${parts[1]}"
            else
                n=1
                provider="${parts[0]}"
                role="${parts[1]}"
            fi
        elif [[ "${#parts[@]}" -eq 3 ]]; then
            if [[ "${parts[0]}" =~ ^[0-9]+$ ]]; then
                n="${parts[0]}"
                provider="${parts[1]}"
                role="${parts[2]}"
            else
                n=1
                provider="${parts[0]}"
                role="${parts[1]}"
                model="${parts[2]}"
            fi
        elif [[ "${#parts[@]}" -eq 4 ]]; then
            n="${parts[0]}"
            provider="${parts[1]}"
            role="${parts[2]}"
            model="${parts[3]}"
        else
            die "too many fields in '$tok' (max 4: N:provider:role:model; for models containing ':' use --model)"
        fi

        [[ "$provider" == "gemini" ]] && provider="agy"
        [[ -z "$role" ]] && role="stock"
        [[ "$n" =~ ^[0-9]+$ ]] || die "bad spec count in '$tok' (use N:provider or N:provider:role[:model])"
        quintet_provider_validate "$provider"
        role="$(quintet_normalize_role "$role")"
        quintet_role_exists "$role" || die "unknown role: '$role' in '$tok'"

        if [[ -n "$model" ]]; then
            for ((i=0; i<n; i++)); do echo "${provider}:${role}:${model}"; done
        else
            for ((i=0; i<n; i++)); do echo "${provider}:${role}"; done
        fi
    done
}

# quintet_team_start <spec> <task> [--cwd dir] [--name name] [--tasks "t1||t2||..."]
# --tasks lets the caller hand each worker a distinct, pre-decomposed subtask.
quintet_team_start() {
    quintet_tmux_available || die "tmux is not installed (required for team mode): see https://github.com/tmux/tmux"
    local spec="" task="" cwd="$PWD" name="" tasks_blob=""
    local skip_auth="${QUINTET_SKIP_AUTH_CHECK:-false}"
    local no_mcp="${QUINTET_NO_MCP:-false}"
    local team_model="${QUINTET_MODEL:-}"
    local team_effort="${QUINTET_EFFORT:-}"
    local safe_mode="${QUINTET_SAFE_MODE:-false}"

    # First two positionals are spec + task; rest are flags.
    [[ $# -ge 1 ]] || die "team start: missing spec (e.g. 2:claude,1:qwen)"
    spec="$1"; shift
    [[ $# -ge 1 ]] || die "team start: missing task description"
    task="$1"; shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cwd)              need_arg "$1" $#; cwd="$2"; shift 2 ;;
            --name)             need_arg "$1" $#; name="$2"; quintet_validate_team_name "$name"; shift 2 ;;
            --tasks)            need_arg "$1" $#; tasks_blob="$2"; shift 2 ;;
            --skip-auth-check)  skip_auth=true; shift ;;
            --no-mcp)           no_mcp=true; shift ;;
            --safe)             safe_mode=true; shift ;;
            --model)            need_arg "$1" $#; team_model="$2"; shift 2 ;;
            --effort)           need_arg "$1" $#; team_effort="$2"; shift 2 ;;
            *) die "unknown team flag: $1" ;;
        esac
    done
    [[ -n "$spec" ]] || die "team start: missing spec (e.g. 2:claude,1:qwen)"
    [[ -n "$task" ]] || die "team start: missing task description"
    [[ -d "$cwd" ]]  || die "team start: --cwd not a directory: $cwd"
    cwd="$(cd "$cwd" && pwd)"

    # Parse in a command substitution and check its status: a die() inside the
    # parser only exits that subshell, so a bad later token must abort here.
    local parsed
    parsed="$(_quintet_parse_spec "$spec")" || exit 1
    local -a workers=()
    [[ -n "$parsed" ]] && mapfile -t workers <<< "$parsed"
    [[ "${#workers[@]}" -ge 1 ]] || die "team start: spec produced zero workers"
    [[ "${#workers[@]}" -le 10 ]] || die "team start: max 10 workers (got ${#workers[@]})"

    # Pre-flight provider auth and readiness verification
    if [[ "$skip_auth" != "true" ]]; then
        local w_entry w_prov custom_launch_var
        for w_entry in "${workers[@]}"; do
            w_prov="${w_entry%%:*}"
            custom_launch_var="QUINTET_$(printf '%s' "$w_prov" | tr '[:lower:]' '[:upper:]')_LAUNCH"
            if [[ -z "${!custom_launch_var:-}" ]]; then
                if ! quintet_provider_ready "$w_prov"; then
                    die "team start: provider '$w_prov' is not ready/authenticated. Run: quintet doctor (or pass --skip-auth-check)"
                fi
            fi
        done
    fi

    [[ -z "$name" ]] && name="$(slugify "$task")"
    [[ -z "$name" ]] && name="team-$(now_epoch)"
    quintet_validate_team_name "$name"

    if quintet_session_exists "$name"; then
        die "team '$name' already running. Use: quintet team status $name (or shutdown $name --force)"
    fi

    # Optional pre-decomposed per-worker subtasks (split on literal '||').
    local -a subtasks=()
    if [[ -n "$tasks_blob" ]]; then
        local rest="$tasks_blob"
        while [[ "$rest" == *"||"* ]]; do
            subtasks+=( "${rest%%||*}" ); rest="${rest#*||}"
        done
        subtasks+=( "$rest" )
    fi

    local tdir; tdir="$(_quintet_team_dir "$name")"
    ensure_dir "$tdir"
    local board="${tdir}/taskboard.md"
    {
        echo "# quintet team: $name"
        echo "_started $(now_iso) — cwd: ${cwd}_"
        echo
        echo "## Shared goal"
        echo "$task"
        echo
        echo "## Workers"
    } > "$board"

    # Build manifest header.
    local manifest="${tdir}/team.json"
    local worker_json="" idx=1
    # Per-worker env files (A4): 0600 files in a private 0700 dir; each worker
    # deletes its own before exec. The trap removes leftovers on abort.
    local envdir
    envdir="$(mktemp -d "${TMPDIR:-/tmp}/quintet-env.XXXXXX")" || die "team start: cannot create env dir"
    chmod 700 "$envdir"
    # shellcheck disable=SC2064  # expand envdir now; the local is gone at EXIT
    trap "rm -rf -- $(printf '%q' "$envdir")" EXIT
    # shellcheck disable=SC2064
    trap "rm -rf -- $(printf '%q' "$envdir"); exit 130" INT TERM
    quintet_session_create "$name" "$cwd"

    local worker_entry provider rem role model worker_name wtask role_prompt
    for worker_entry in "${workers[@]}"; do
        provider="${worker_entry%%:*}"
        rem="${worker_entry#*:}"
        role="${rem%%:*}"
        model=""
        if [[ "$rem" == *:* ]]; then
            model="${rem#*:}"
        fi
        [[ "$role" == "$worker_entry" || -z "$role" ]] && role="stock"
        [[ -z "$model" ]] && model="$team_model"

        if [[ "$role" == "stock" ]]; then
            worker_name="w${idx}-${provider}"
        else
            worker_name="w${idx}-${provider}-${role}"
        fi

        # Choose this worker's task: distinct subtask if provided, else shared goal.
        if [[ "${#subtasks[@]}" -ge "$idx" ]]; then
            wtask="${subtasks[$((idx-1))]}"
        else
            wtask="$task"
        fi

        # Resolve role instructions if defined
        role_prompt="$(quintet_role_prompt "$role")"
        local role_block=""
        if [[ -n "$role_prompt" ]]; then
            role_block="${role_prompt}

"
        fi

        # The full instruction injected into the agent REPL.
        local injected
        injected="${role_block}You are ${worker_name}, a worker in quintet team '${name}' (role: ${role}). Working dir: ${cwd}. \
Shared team goal: ${task} \
Your assignment: ${wtask} \
Coordinate by appending status to ${board} (one line, prefixed with [${worker_name}]). \
Avoid editing files another worker owns. When done, write a final [${worker_name}] DONE line to the taskboard."

        log INFO "spawning $worker_name ($(quintet_provider_emoji "$provider") $provider, role: $role)"
        local envf="${envdir}/${worker_name}.env"
        quintet_write_worker_env "$provider" "$envf" || die "team start: cannot write worker env file"
        quintet_window_spawn "$name" "$worker_name" "$cwd" "$(quintet_provider_launch_cmd "$provider" "$no_mcp" "$model" "$team_effort" "$safe_mode")" "$envf" || continue
        echo "- **${worker_name}** ($provider, role: ${role}): ${wtask}" >> "$board"
        worker_json="${worker_json}${worker_json:+,}{\"name\": $(json_escape "${worker_name}"), \"provider\": $(json_escape "${provider}"), \"role\": $(json_escape "${role}"), \"model\": $(json_escape "${model:-default}")}"

        # Defer task injection: warm up the REPL first, then send.
        ( sleep "$(quintet_provider_warmup "$provider")"; quintet_window_send "$name" "$worker_name" "$injected" ) &
        idx=$((idx+1))
    done

    {
        printf '{\n'
        printf '  "name": %s,\n'    "$(json_escape "$name")"
        printf '  "cwd": %s,\n'     "$(json_escape "$cwd")"
        printf '  "session": %s,\n' "$(json_escape "$(quintet_tmux_session "$name")")"
        printf '  "no_mcp": %s,\n'  "$no_mcp"
        printf '  "safe_mode": %s,\n' "$safe_mode"
        printf '  "started": %s,\n' "$(json_escape "$(now_iso)")"
        printf '  "goal": %s,\n'    "$(json_escape "$task")"
        printf '  "workers": [%s]\n' "$worker_json"
        printf '}\n'
    } > "$manifest"

    wait   # let deferred task injections finish before returning
    # Workers delete their env file on start; give slow starters a moment, then
    # remove whatever is left (a worker that never started must not leave secrets).
    local _w
    for _w in 1 2 3 4 5 6 7 8 9 10; do
        compgen -G "${envdir}/*.env" >/dev/null || break
        sleep 0.5
    done
    rm -rf -- "$envdir"
    trap - EXIT INT TERM
    log INFO "team '$name' started with ${#workers[@]} worker(s). Attach: tmux attach -t $(quintet_tmux_session "$name")"
    printf "Tmux session: tmux attach -t %s\n" "$(quintet_tmux_session "$name")" >&2
    echo "$name"
}

_quintet_detect_worker_modal() {
    local team="$1" worker="$2"
    local buf
    buf="$(quintet_window_capture "$team" "$worker" 40 2>/dev/null || true)"
    [[ -z "$buf" ]] && return 1

    local tail_buf
    tail_buf="$(echo "$buf" | tail -n 15)"

    if echo "$tail_buf" | grep -Ei 'do you trust this folder|trust folder|trust the authors' >/dev/null 2>&1; then
        echo "TRUST_FOLDER"
        return 0
    elif echo "$tail_buf" | grep -Ei 'allow tool call|approve.*tool|\[y/N\]|\(y/n\)|do you want to proceed|run command\?' >/dev/null 2>&1; then
        echo "TOOL_APPROVAL"
        return 0
    elif echo "$tail_buf" | grep -Ei 'login required|sign in|authenticate|api key|enter token' >/dev/null 2>&1; then
        echo "AUTH_REQUIRED"
        return 0
    elif echo "$tail_buf" | grep -Ei 'press enter to continue|press any key' >/dev/null 2>&1; then
        echo "KEY_PAUSE"
        return 0
    fi
    return 1
}

quintet_team_status() {
    local name="${1:-}"; [[ -n "$name" ]] || die "team status: missing team name"
    quintet_validate_team_name "$name"
    if ! quintet_session_exists "$name"; then
        log WARN "team '$name' is not running (no tmux session $(quintet_tmux_session "$name"))"
        return 1
    fi
    local tdir; tdir="$(_quintet_team_dir "$name")"
    echo "Team: $name   session: $(quintet_tmux_session "$name")"
    [[ -f "${tdir}/team.json" ]] && have_jq && \
        echo "Goal: $(jq -r '.goal' "${tdir}/team.json")"
    echo "Workers:"
    local w cmd modal
    while IFS= read -r w; do
        [[ -z "$w" ]] && continue
        cmd="$(quintet_window_command "$name" "$w")"
        modal="$(_quintet_detect_worker_modal "$name" "$w" || true)"
        if [[ -n "$modal" ]]; then
            printf '  • %-18s running: %-10s  ⚠️  STALLED_MODAL: %s\n' "$w" "${cmd:-idle}" "$modal"
        else
            printf '  • %-18s running: %s\n' "$w" "${cmd:-idle}"
        fi
    done < <(quintet_window_list "$name")
    if [[ -f "${tdir}/taskboard.md" ]]; then
        echo "Taskboard tail:"
        tail -8 "${tdir}/taskboard.md" | sed 's/^/    /'
    fi
}

quintet_team_doctor() {
    local name="${1:-}"; [[ -n "$name" ]] || die "team doctor: missing team name"
    quintet_validate_team_name "$name"
    if ! quintet_session_exists "$name"; then
        echo "❌ Team '$name' is not running (no tmux session $(quintet_tmux_session "$name"))"
        return 1
    fi

    echo "==> Diagnosing team: $name (session: $(quintet_tmux_session "$name"))"
    local issues=0
    local w cmd modal
    while IFS= read -r w; do
        [[ -z "$w" ]] && continue
        cmd="$(quintet_window_command "$name" "$w")"
        modal="$(_quintet_detect_worker_modal "$name" "$w" || true)"
        if [[ -n "$modal" ]]; then
            issues=$((issues + 1))
            echo "  ⚠️  Worker '$w' is STALLED on modal: $modal"
            echo "     Active command: ${cmd:-idle}"
            echo "     Recent pane output:"
            quintet_window_capture "$name" "$w" 6 2>/dev/null | sed 's/^/       | /'
            echo "     Remediation: Attach to resolve: tmux attach -t $(quintet_tmux_session "$name")"
            echo "                  Or inject answer: quintet team send \"$name\" \"$w\" \"y\""
        else
            echo "  ✅ Worker '$w': operational (running: ${cmd:-idle})"
        fi
    done < <(quintet_window_list "$name")

    if [[ $issues -eq 0 ]]; then
        echo "==> All workers operational. No modal stalls detected."
        return 0
    else
        echo "==> Total stalled workers detected: $issues"
        return 1
    fi
}

quintet_team_capture() {
    local name="${1:-}" worker="${2:-}" lines="${3:-40}"
    [[ -n "$name" ]] || die "team capture: missing team name"
    quintet_validate_team_name "$name"
    quintet_session_exists "$name" || die "team '$name' is not running"
    if [[ -n "$worker" ]]; then
        quintet_window_capture "$name" "$worker" "$lines"
    else
        local w
        while IFS= read -r w; do
            [[ -z "$w" ]] && continue
            echo "════════ $w ════════"
            quintet_window_capture "$name" "$w" "$lines"
            echo
        done < <(quintet_window_list "$name")
    fi
}

quintet_team_send() {
    local name="${1:-}" worker="${2:-}" text="${3:-}"
    [[ -n "$name" && -n "$worker" && -n "$text" ]] || die "usage: quintet team send <name> <worker> <text>"
    quintet_validate_team_name "$name"
    quintet_session_exists "$name" || die "team '$name' is not running"
    quintet_window_send "$name" "$worker" "$text" \
        || die "team send: no worker window '$worker' in team '$name' (worker names are exact; see: quintet team status $name)"
    log INFO "sent to ${name}/${worker}"
}

quintet_team_shutdown() {
    local name="${1:-}" force="${2:-}"
    [[ -n "$name" ]] || die "team shutdown: missing team name"
    quintet_validate_team_name "$name"
    if ! quintet_session_exists "$name"; then
        log WARN "team '$name' has no live session; cleaning state only"
    fi
    quintet_session_kill "$name"
    if [[ "$force" == "--force" || "$force" == "-f" ]]; then
        rm -rf "$(_quintet_team_dir "$name")" 2>/dev/null || true
        log INFO "team '$name' shut down and state purged"
    else
        log INFO "team '$name' shut down (state kept under $(_quintet_team_dir "$name"))"
    fi
}

quintet_team_list() {
    qtmux list-sessions -F '#{session_name}' 2>/dev/null \
        | grep '^quintet-' | sed 's/^quintet-/  • /' || echo "  (no quintet teams running)"
}
