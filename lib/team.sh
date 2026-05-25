#!/usr/bin/env bash
# quintet/lib/team.sh — persistent tmux worker-team runtime (omc-teams style),
# extended to all five providers (claude, codex, gemini, copilot, qwen).
#
# A "team" is a detached tmux session of long-lived worker windows. Each worker
# is an interactive agent CLI that receives a task via send-keys and then works
# autonomously in the shared working directory. Coordination is file-based: a
# team manifest plus a shared task board the orchestrating Claude can read/write.
# ─────────────────────────────────────────────────────────────────────────────

_quintet_team_dir() { echo "${QUINTET_STATE_DIR}/teams/$1"; }

# Parse a team spec like "2:claude,1:qwen,1:copilot" into a flat worker list.
# Echoes one provider per line (so 2:claude -> two "claude" lines). Validates each.
_quintet_parse_spec() {
    local spec="$1" tok n provider i
    IFS=',' read -ra _toks <<< "$spec"
    for tok in "${_toks[@]}"; do
        tok="${tok// /}"
        [[ -z "$tok" ]] && continue
        if [[ "$tok" == *:* ]]; then
            n="${tok%%:*}"; provider="${tok##*:}"
        else
            n=1; provider="$tok"
        fi
        [[ "$n" =~ ^[0-9]+$ ]] || die "bad spec count in '$tok' (use N:provider)"
        quintet_provider_validate "$provider"
        for ((i=0; i<n; i++)); do echo "$provider"; done
    done
}

# quintet_team_start <spec> <task> [--cwd dir] [--name name] [--tasks "t1||t2||..."]
# --tasks lets the caller hand each worker a distinct, pre-decomposed subtask.
quintet_team_start() {
    quintet_tmux_available || die "tmux is not installed (required for team mode): see https://github.com/tmux/tmux"
    local spec="" task="" cwd="$PWD" name="" tasks_blob=""
    # First two positionals are spec + task; rest are flags.
    spec="$1"; shift
    task="$1"; shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cwd)   cwd="$2"; shift 2 ;;
            --name)  name="$2"; shift 2 ;;
            --tasks) tasks_blob="$2"; shift 2 ;;
            *) die "unknown team flag: $1" ;;
        esac
    done
    [[ -n "$spec" ]] || die "team start: missing spec (e.g. 2:claude,1:qwen)"
    [[ -n "$task" ]] || die "team start: missing task description"
    [[ -d "$cwd" ]]  || die "team start: --cwd not a directory: $cwd"
    cwd="$(cd "$cwd" && pwd)"

    local -a workers=()
    mapfile -t workers < <(_quintet_parse_spec "$spec")
    [[ "${#workers[@]}" -ge 1 ]] || die "team start: spec produced zero workers"
    [[ "${#workers[@]}" -le 10 ]] || die "team start: max 10 workers (got ${#workers[@]})"

    [[ -z "$name" ]] && name="$(slugify "$task")"
    [[ -z "$name" ]] && name="team-$(now_epoch)"

    if quintet_session_exists "$name"; then
        die "team '$name' already running. Use: quintet team status $name (or shutdown $name --force)"
    fi

    # Optional pre-decomposed per-worker subtasks (split on '||').
    local -a subtasks=()
    if [[ -n "$tasks_blob" ]]; then
        IFS='|' read -ra _raw <<< "${tasks_blob//||/$'\x1f'}"
        # Above is fragile across shells; do an explicit split on the literal '||'.
        subtasks=()
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
    quintet_session_create "$name" "$cwd"

    local provider worker_name wtask
    for provider in "${workers[@]}"; do
        worker_name="w${idx}-${provider}"
        # Choose this worker's task: distinct subtask if provided, else shared goal.
        if [[ "${#subtasks[@]}" -ge "$idx" ]]; then
            wtask="${subtasks[$((idx-1))]}"
        else
            wtask="$task"
        fi
        # The full instruction injected into the agent REPL.
        local injected
        injected="You are ${worker_name}, a worker in quintet team '${name}'. Working dir: ${cwd}. \
Shared team goal: ${task} \
Your assignment: ${wtask} \
Coordinate by appending status to ${board} (one line, prefixed with [${worker_name}]). \
Avoid editing files another worker owns. When done, write a final [${worker_name}] DONE line to the taskboard."

        log INFO "spawning $worker_name ($(quintet_provider_emoji "$provider") $provider)"
        quintet_window_spawn "$name" "$worker_name" "$cwd" "$(quintet_provider_launch_cmd "$provider")" || continue
        echo "- **${worker_name}** ($provider): ${wtask}" >> "$board"
        worker_json="${worker_json}${worker_json:+,}{\"name\":\"${worker_name}\",\"provider\":\"${provider}\"}"

        # Defer task injection: warm up the REPL first, then send.
        ( sleep "$(quintet_provider_warmup "$provider")"; quintet_window_send "$name" "$worker_name" "$injected" ) &
        idx=$((idx+1))
    done

    {
        printf '{\n'
        printf '  "name": %s,\n'    "$(json_escape "$name")"
        printf '  "cwd": %s,\n'     "$(json_escape "$cwd")"
        printf '  "session": %s,\n' "$(json_escape "$(quintet_tmux_session "$name")")"
        printf '  "started": %s,\n' "$(json_escape "$(now_iso)")"
        printf '  "goal": %s,\n'    "$(json_escape "$task")"
        printf '  "workers": [%s]\n' "$worker_json"
        printf '}\n'
    } > "$manifest"

    wait   # let deferred task injections finish before returning
    log INFO "team '$name' started with ${#workers[@]} worker(s). Attach: tmux attach -t $(quintet_tmux_session "$name")"
    echo "$name"
}

quintet_team_status() {
    local name="$1"; [[ -n "$name" ]] || die "team status: missing team name"
    if ! quintet_session_exists "$name"; then
        log WARN "team '$name' is not running (no tmux session $(quintet_tmux_session "$name"))"
        return 1
    fi
    local tdir; tdir="$(_quintet_team_dir "$name")"
    echo "Team: $name   session: $(quintet_tmux_session "$name")"
    [[ -f "${tdir}/team.json" ]] && have_jq && \
        echo "Goal: $(jq -r '.goal' "${tdir}/team.json")"
    echo "Workers:"
    local w
    while IFS= read -r w; do
        [[ -z "$w" ]] && continue
        printf '  • %-18s running: %s\n' "$w" "$(quintet_window_command "$name" "$w")"
    done < <(quintet_window_list "$name")
    if [[ -f "${tdir}/taskboard.md" ]]; then
        echo "Taskboard tail:"
        tail -8 "${tdir}/taskboard.md" | sed 's/^/    /'
    fi
}

quintet_team_capture() {
    local name="$1" worker="${2:-}" lines="${3:-40}"
    [[ -n "$name" ]] || die "team capture: missing team name"
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
    local name="$1" worker="$2" text="$3"
    [[ -n "$name" && -n "$worker" && -n "$text" ]] || die "usage: quintet team send <name> <worker> <text>"
    quintet_session_exists "$name" || die "team '$name' is not running"
    quintet_window_send "$name" "$worker" "$text"
    log INFO "sent to ${name}/${worker}"
}

quintet_team_shutdown() {
    local name="$1" force="${2:-}"
    [[ -n "$name" ]] || die "team shutdown: missing team name"
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
    tmux list-sessions -F '#{session_name}' 2>/dev/null \
        | grep '^quintet-' | sed 's/^quintet-/  • /' || echo "  (no quintet teams running)"
}
