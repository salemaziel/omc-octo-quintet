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
        [[ -z "$model" ]] || quintet_validate_model_value "model in '$tok'" "$model"

        if [[ -n "$model" ]]; then
            for ((i=0; i<n; i++)); do echo "${provider}:${role}:${model}"; done
        else
            for ((i=0; i<n; i++)); do echo "${provider}:${role}"; done
        fi
    done
}

# quintet_team_start <spec> <task> [--cwd dir] [--name name] [--tasks "t1||t2||..."]
# --tasks lets the caller hand each worker a distinct, pre-decomposed subtask.
# --trust-cwd lets the kickoff answer Claude's first-run "trust this folder"
# dialog with Yes (only that exact dialog); without it the task is held.
quintet_team_start() {
    quintet_tmux_available || die "tmux is not installed (required for team mode): see https://github.com/tmux/tmux"
    local spec="" task="" cwd="$PWD" name="" tasks_blob=""
    local skip_auth="${QUINTET_SKIP_AUTH_CHECK:-false}"
    local no_mcp="${QUINTET_NO_MCP:-false}"
    # --model/--effort: bare value = team-wide default, or provider=value[,...]
    # (resolved per worker by quintet_resolve_model/_effort, decision 3).
    local model_map="" model_bare="" effort_map="" effort_bare=""
    local safe_mode="${QUINTET_SAFE_MODE:-false}"
    local trust_cwd="${QUINTET_TRUST_CWD:-false}"

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
            --trust-cwd)        trust_cwd=true; shift ;;
            --model)            need_arg "$1" $#; quintet_parse_cli_value --model "$2" model_map model_bare; shift 2 ;;
            --effort)           need_arg "$1" $#; quintet_parse_cli_value --effort "$2" effort_map effort_bare; shift 2 ;;
            *) die "unknown team flag: $1" ;;
        esac
    done
    [[ "$trust_cwd" == true ]] || trust_cwd=false
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

    # Resolve each worker's model/effort now (same inputs as the spawn loop), so a
    # bad env-sourced value dies before any session or state exists (S-L4, R-L1).
    local w_chk w_rem w_spec
    for w_chk in "${workers[@]}"; do
        w_rem="${w_chk#*:}"; w_spec=""
        [[ "$w_rem" == *:* ]] && w_spec="${w_rem#*:}"
        quintet_resolve_model "${w_chk%%:*}" "$model_map" "$w_spec" "$model_bare" >/dev/null
        quintet_resolve_effort "${w_chk%%:*}" "$effort_map" "$effort_bare" >/dev/null
    done

    # Pre-flight provider auth and readiness verification
    if [[ "$skip_auth" != "true" ]]; then
        local w_entry w_prov custom_launch_var
        for w_entry in "${workers[@]}"; do
            w_prov="${w_entry%%:*}"
            custom_launch_var="QUINTET_$(printf '%s' "$w_prov" | tr '[:lower:]' '[:upper:]')_LAUNCH"
            local legacy_launch=""
            [[ "$w_prov" == "agy" ]] && legacy_launch="${QUINTET_GEMINI_LAUNCH:-}"   # legacy name launch_cmd still honors
            if [[ -z "${!custom_launch_var:-}" && -z "$legacy_launch" ]]; then
                if ! quintet_provider_ready "$w_prov"; then
                    die "team start: provider '$w_prov' is not ready/authenticated. Run: quintet doctor (or pass --skip-auth-check)"
                fi
            fi
        done
    fi

    [[ -z "$name" ]] && name="$(slugify "$task")"
    [[ -z "$name" ]] && name="team-$(now_epoch)"
    quintet_validate_team_name "$name"
    # quintet-fleet-<epoch>-<pid>-<n> is the fleet session namespace (prune kills old ones).
    [[ "$name" =~ ^fleet-[0-9]+-[0-9]+-[0-9]+$ ]] && die "team name '$name' is reserved for fleet sessions"

    # Never write through a symlinked state dir, teams/, locks/ or team dir (S-M2).
    quintet_state_guard "$name"
    # Hold the team lock from the liveness check until the session exists, so a
    # concurrent prune can't delete this team's state in between. The EXIT trap
    # releases it on every die path below.
    quintet_lock "$name" || die "team start: team '$name' is locked by another quintet process (start or prune in progress). If none is running, remove the lock: rm -rf -- $(printf '%q' "$(quintet_lock_path "$name")")"
    local unlock_cmd; unlock_cmd="quintet_unlock $(printf '%q' "$name")"
    # shellcheck disable=SC2064  # expand name now
    trap "$unlock_cmd" EXIT
    # shellcheck disable=SC2064
    trap "$unlock_cmd; exit 130" INT TERM

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
    # A zero-worker failure removes the team dir only if this start created it;
    # otherwise it restores the prior taskboard.md (R-L2).
    local tdir_new=false; [[ -e "$tdir" || -L "$tdir" ]] || tdir_new=true
    ensure_dir "$tdir"
    quintet_state_guard "$name"
    # State files are written to a temp file in the team dir and renamed into
    # place, so a pre-placed taskboard.md / team.json symlink is replaced, never
    # written through (S-M2).
    local board="${tdir}/taskboard.md" board_tmp board_prev=""
    # Keep a copy of a prior run's regular-file taskboard (never a symlink's target).
    if [[ "$tdir_new" == false && -f "$board" && ! -L "$board" ]]; then
        board_prev="$(mktemp "${tdir}/.taskboard.prev.XXXXXX")" && cp -p -- "$board" "$board_prev" \
            || die "team start: cannot back up ${board}"
    fi
    board_tmp="$(mktemp "${tdir}/.taskboard.XXXXXX")" || die "team start: cannot write ${board}"
    {
        echo "# quintet team: $name"
        echo "_started $(now_iso) — cwd: ${cwd}_"
        echo
        echo "## Shared goal"
        echo "$task"
        echo
        echo "## Workers"
    } > "$board_tmp"
    _quintet_rename "$board_tmp" "$board" || { rm -f -- "$board_tmp"; die "team start: cannot write ${board}"; }

    # Build manifest header.
    local manifest="${tdir}/team.json"
    local worker_json="" idx=1 started=0
    # Per-worker env files (A4): 0600 files in a private 0700 dir; each worker
    # deletes its own before exec. The trap removes leftovers on abort.
    local envdir
    envdir="$(mktemp -d "${TMPDIR:-/tmp}/quintet-env.XXXXXX")" || die "team start: cannot create env dir"
    chmod 700 "$envdir"
    # shellcheck disable=SC2064  # expand envdir now; the local is gone at EXIT
    trap "rm -rf -- $(printf '%q' "$envdir"); $unlock_cmd" EXIT
    # shellcheck disable=SC2064
    trap "rm -rf -- $(printf '%q' "$envdir"); $unlock_cmd; exit 130" INT TERM
    quintet_session_create "$name" "$cwd"

    local worker_entry provider rem role model effort mcp_eff worker_name wtask role_prompt
    for worker_entry in "${workers[@]}"; do
        provider="${worker_entry%%:*}"
        rem="${worker_entry#*:}"
        role="${rem%%:*}"
        model=""
        if [[ "$rem" == *:* ]]; then
            model="${rem#*:}"
        fi
        [[ "$role" == "$worker_entry" || -z "$role" ]] && role="stock"
        model="$(quintet_resolve_model "$provider" "$model_map" "$model" "$model_bare")"
        effort="$(quintet_resolve_effort "$provider" "$effort_map" "$effort_bare")"
        mcp_eff="$(quintet_no_mcp_effective "$provider" "$no_mcp")"

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
        quintet_window_spawn "$name" "$worker_name" "$cwd" "$(quintet_provider_launch_cmd "$provider" "$no_mcp" "$model" "$effort" "$safe_mode")" "$envf" || { log ERROR "worker $worker_name failed to start; skipping it (later workers keep their numbers)"; idx=$((idx+1)); continue; }
        started=$((started+1))
        echo "- **${worker_name}** ($provider, role: ${role}): ${wtask}" >> "$board"
        worker_json="${worker_json}${worker_json:+,}{\"name\": $(json_escape "${worker_name}"), \"provider\": $(json_escape "${provider}"), \"role\": $(json_escape "${role}"), \"model\": $(json_escape "${model:-default}"), \"effort\": $(json_escape "${effort:-default}"), \"no_mcp_effective\": $(json_escape "$mcp_eff")}"

        # Defer task injection: warm up the REPL first, then send only if no
        # first-run dialog is showing (Enter would answer it, e.g. "No, exit").
        ( sleep "$(quintet_provider_warmup "$provider")"
          _quintet_team_kickoff "$name" "$worker_name" "$provider" "$trust_cwd" "$injected" ) &
        idx=$((idx+1))
    done

    # Zero workers started: don't leave a leader-only session behind (C-M3).
    # The EXIT trap removes the env dir and releases the lock. Only what this
    # start wrote is removed: the whole team dir if it created it, else just its
    # taskboard.md (the prior one is put back). team.json isn't written yet (R-L2).
    if [[ $started -eq 0 ]]; then
        quintet_session_kill "$name"
        if [[ "$tdir_new" == true ]]; then
            quintet_safe_rm_dir "$tdir" "${QUINTET_STATE_DIR%/}/teams" || log WARN "team start: could not remove $tdir"
        elif [[ -n "$board_prev" ]]; then
            _quintet_rename "$board_prev" "$board" || log WARN "team start: could not restore $board"
        else
            rm -f -- "$board"
        fi
        die "team start: none of the ${#workers[@]} worker(s) started; session and this start's team state removed"
    fi
    [[ -z "$board_prev" ]] || rm -f -- "$board_prev"

    local manifest_tmp
    manifest_tmp="$(mktemp "${tdir}/.team.json.XXXXXX")" || die "team start: cannot write ${manifest}"
    {
        printf '{\n'
        printf '  "name": %s,\n'    "$(json_escape "$name")"
        printf '  "cwd": %s,\n'     "$(json_escape "$cwd")"
        printf '  "session": %s,\n' "$(json_escape "$(quintet_tmux_session "$name")")"
        printf '  "no_mcp": %s,\n'  "$no_mcp"
        printf '  "safe_mode": %s,\n' "$safe_mode"
        printf '  "trust_cwd": %s,\n' "$trust_cwd"
        printf '  "started": %s,\n' "$(json_escape "$(now_iso)")"
        printf '  "goal": %s,\n'    "$(json_escape "$task")"
        printf '  "workers": [%s]\n' "$worker_json"
        printf '}\n'
    } > "$manifest_tmp"
    _quintet_rename "$manifest_tmp" "$manifest" || { rm -f -- "$manifest_tmp"; die "team start: cannot write ${manifest}"; }

    wait   # let deferred task injections finish before returning
    # Workers delete their env file on start; give slow starters a moment, then
    # remove whatever is left (a worker that never started must not leave secrets).
    local _w
    for _w in 1 2 3 4 5 6 7 8 9 10; do
        compgen -G "${envdir}/*.env" >/dev/null || break
        sleep 0.5
    done
    rm -rf -- "$envdir"
    quintet_unlock "$name"
    trap - EXIT INT TERM
    log INFO "team '$name' started with ${started} of ${#workers[@]} worker(s). Attach: tmux attach -t $(quintet_tmux_session "$name")"
    printf "Tmux session: tmux attach -t %s\n" "$(quintet_tmux_session "$name")" >&2
    echo "$name"
}

# _quintet_detect_worker_modal <team> <worker>
# Status: 0 = modal found (name on stdout), 1 = no recognized modal, 2 = the pane
# could not be captured (inspection error). Whitespace-only lines are dropped
# before taking the last 15, so a prompt scrolled above blank rows is still seen.
# Auth patterns are anchored to prompt shapes (POSIX classes only, no \s) so a
# log line like "Implemented API key validation" doesn't match. A log-in/sign-in
# line must be the whole prompt ("Please log in to continue", "Sign in:"), so
# "Login successful" / "Sign in complete" don't match.
_quintet_detect_worker_modal() {
    local team="$1" worker="$2"
    local buf
    buf="$(quintet_window_capture "$team" "$worker" 40 2>/dev/null)" || return 2

    local tail_buf
    tail_buf="$(printf '%s\n' "$buf" | grep -v '^[[:space:]]*$' | tail -n 15)"
    [[ -z "$tail_buf" ]] && return 1

    if echo "$tail_buf" | grep -Ei 'do you trust this folder|trust folder|trust the authors|Is this a project you created or one you trust|Yes, I trust this folder|trust the files in this folder|trust the contents of this directory' >/dev/null 2>&1; then
        echo "TRUST_FOLDER"
        return 0
    elif echo "$tail_buf" | grep -Ei 'allow tool call|approve.*tool|\[y/N\]|\(y/n\)|do you want to proceed|run command\?' >/dev/null 2>&1; then
        echo "TOOL_APPROVAL"
        return 0
    elif echo "$tail_buf" | grep -Ei -e '^[[:space:]]*(please[[:space:]]+)?(log[[:space:]]?in|sign[[:space:]]in)([[:space:]]+(to|with|using|via)[[:space:]].*)?[[:space:]]*[:?.!>]*[[:space:]]*$' -e 'Enter (your )?(API key|token)' -e '^[[:space:]]*(login|authentication) required' >/dev/null 2>&1; then
        echo "AUTH_REQUIRED"
        return 0
    elif echo "$tail_buf" | grep -Ei 'press enter to continue|press any key' >/dev/null 2>&1; then
        echo "KEY_PAUSE"
        return 0
    fi
    return 1
}

# _quintet_trust_dialog_selected <capture> <line> — 0 when the capture shows
# Claude's trust dialog layout ("No, exit" directly above "Yes, I trust this
# folder", ignoring blank rows) and the ❯ cursor is on <line> ("no" or "yes").
_quintet_trust_dialog_selected() {
    printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | awk -v want="$2" '
        prev ~ /^[[:space:]]*(❯[[:space:]]*)?No, exit[[:space:]]*$/ &&
        $0 ~ /^[[:space:]]*(❯[[:space:]]*)?Yes, I trust this folder[[:space:]]*$/ {
            n = (prev ~ /❯/); y = ($0 ~ /❯/)
            if (want == "yes" ? (y && !n) : (n && !y)) found = 1
        }
        { prev = $0 }
        END { exit !found }'
}

# _quintet_team_hold <team> <worker> <modal> <text> — keep <text> in
# held/<worker>.txt (0600 in a 0700 dir, written via temp + rename so a planted
# symlink is replaced, not followed), note it on the taskboard and tell the user
# how to resume.
_quintet_team_hold() {
    local team="$1" worker="$2" modal="$3" text="$4" tdir hdir tmp
    tdir="$(_quintet_team_dir "$team")"; hdir="${tdir}/held"
    quintet_state_guard "$team"
    quintet_refuse_symlink "$hdir" "held-task dir"
    mkdir -m 700 "$hdir" 2>/dev/null   # may already exist (another held worker)
    [[ -d "$hdir" && ! -L "$hdir" ]] && chmod 700 "$hdir" || die "team start: cannot create $hdir"
    tmp="$(mktemp "${hdir}/.${worker}.XXXXXX")" || die "team start: cannot write held task for $worker"
    printf '%s\n' "$text" > "$tmp" && chmod 600 "$tmp" && _quintet_rename "$tmp" "${hdir}/${worker}.txt" \
        || { rm -f -- "$tmp"; die "team start: cannot write held task for $worker"; }
    [[ -L "${tdir}/taskboard.md" ]] || echo "[quintet] ${worker} HELD: ${modal}" >> "${tdir}/taskboard.md"
    log WARN "${worker} HELD: ${modal} on screen, task not sent. Attach: tmux attach -t $(quintet_tmux_session "$team") (answer it), then: quintet team resume ${team} ${worker}"
}

# _quintet_team_kickoff <team> <worker> <provider> <trust_cwd> <text> — wait for
# the pane to draw (up to ~20s), then send <text> unless a modal is showing.
# With trust_cwd, a claude worker on the exact trust dialog gets Down (checked to
# land on "Yes, I trust this folder") and Enter; anything else is held.
_quintet_team_kickoff() {
    local team="$1" worker="$2" provider="$3" trust_cwd="$4" text="$5" buf modal rc i
    for ((i=0; i<40; i++)); do
        buf="$(quintet_window_capture "$team" "$worker" 40)" && [[ "$buf" == *[![:space:]]* ]] && break
        sleep 0.5
    done
    modal="$(_quintet_detect_worker_modal "$team" "$worker")"; rc=$?
    [[ $rc -eq 1 ]] && { quintet_window_send "$team" "$worker" "$text"; return; }
    [[ $rc -eq 2 ]] && modal="INSPECTION_ERROR"
    if [[ "$modal" == TRUST_FOLDER && "$trust_cwd" == true && "$provider" == claude ]] \
        && _quintet_trust_dialog_selected "$(quintet_window_capture "$team" "$worker" 40)" no; then
        quintet_window_key "$team" "$worker" Down
        sleep 0.5
        if _quintet_trust_dialog_selected "$(quintet_window_capture "$team" "$worker" 40)" yes; then
            log INFO "${worker}: answering the trust dialog with 'Yes, I trust this folder' (--trust-cwd)"
            quintet_window_key "$team" "$worker" Enter
            sleep "$(quintet_provider_warmup "$provider")"
            modal="$(_quintet_detect_worker_modal "$team" "$worker")"; rc=$?
            [[ $rc -eq 1 ]] && { quintet_window_send "$team" "$worker" "$text"; return; }
            [[ $rc -eq 2 ]] && modal="INSPECTION_ERROR"
        fi
    fi
    _quintet_team_hold "$team" "$worker" "$modal" "$text"
}

# quintet_team_resume <team> [worker] — send held kickoff tasks (all, or one
# worker's) whose pane no longer shows a modal; refuse the rest.
quintet_team_resume() {
    local name="${1:-}" only="${2:-}"
    [[ -n "$name" ]] || die "usage: quintet team resume <name> [worker]"
    quintet_validate_team_name "$name"
    [[ -z "$only" || "$only" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || die "team resume: invalid worker name '$only'"
    quintet_session_exists "$name" || die "team '$name' is not running"
    quintet_state_guard "$name"
    local hdir; hdir="$(_quintet_team_dir "$name")/held"
    quintet_refuse_symlink "$hdir" "held-task dir"
    local -a files=()
    if [[ -n "$only" ]]; then
        [[ -f "${hdir}/${only}.txt" ]] || die "team resume: no held task for '$only' in team '$name'"
        files=( "${hdir}/${only}.txt" )
    elif [[ -d "$hdir" ]]; then
        local f; for f in "$hdir"/*.txt; do [[ -e "$f" ]] && files+=( "$f" ); done
    fi
    [[ ${#files[@]} -ge 1 ]] || { log INFO "team '$name' has no held tasks"; return 0; }
    local f w modal rc failed=0 text
    for f in "${files[@]}"; do
        w="$(basename "$f" .txt)"
        if [[ -L "$f" || ! -f "$f" ]]; then
            log ERROR "team resume: $w: held file is not a regular file; skipped"; failed=1; continue
        fi
        modal="$(_quintet_detect_worker_modal "$name" "$w")"; rc=$?
        if [[ $rc -eq 0 ]]; then
            log ERROR "team resume: $w still shows a modal ($modal); answer it first: tmux attach -t $(quintet_tmux_session "$name")"
            failed=1; continue
        elif [[ $rc -eq 2 ]]; then
            log ERROR "team resume: $w: pane capture failed (no such worker window?); task kept in $f"
            failed=1; continue
        fi
        text="$(cat -- "$f")"
        if quintet_window_send "$name" "$w" "$text"; then
            rm -f -- "$f"
            log INFO "resumed ${name}/${w}"
        else
            log ERROR "team resume: send to $w failed; task kept in $f"; failed=1
        fi
    done
    return "$failed"
}

# _quintet_manifest_workers <team> — worker names from team.json, one per line.
# Returns 1 when there is no manifest or no jq to read it (caller skips the check).
_quintet_manifest_workers() {
    local f; f="$(_quintet_team_dir "$1")/team.json"
    [[ -f "$f" ]] && have_jq || return 1
    jq -r '.workers[].name' "$f" 2>/dev/null
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
    local w cmd modal rc dst
    while IFS= read -r w; do
        [[ -z "$w" ]] && continue
        if dst="$(quintet_window_dead_status "$name" "$w")"; then
            printf '  • %-18s ❌ EXITED (status %s)\n' "$w" "$dst"
            continue
        fi
        cmd="$(quintet_window_command "$name" "$w")"
        modal="$(_quintet_detect_worker_modal "$name" "$w")"; rc=$?
        if [[ $rc -eq 2 ]]; then
            printf '  • %-18s running: %-10s  ⚠️  INSPECTION_ERROR: pane capture failed\n' "$w" "${cmd:-idle}"
        elif [[ $rc -eq 0 && -n "$modal" ]]; then
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
    local w cmd modal rc dst
    local -a windows=()
    while IFS= read -r w; do
        [[ -z "$w" ]] && continue
        windows+=( "$w" )
        if dst="$(quintet_window_dead_status "$name" "$w")"; then
            issues=$((issues + 1))
            echo "  ❌ Worker '$w' EXITED (status $dst); its CLI is no longer running"
            echo "     Recent pane output:"
            quintet_window_capture "$name" "$w" 6 2>/dev/null | sed 's/^/       | /'
            continue
        fi
        cmd="$(quintet_window_command "$name" "$w")"
        modal="$(_quintet_detect_worker_modal "$name" "$w")"; rc=$?
        if [[ $rc -eq 2 ]]; then
            issues=$((issues + 1))
            echo "  ⚠️  Worker '$w': inspection error (pane capture failed; running: ${cmd:-idle})"
        elif [[ $rc -eq 0 && -n "$modal" ]]; then
            issues=$((issues + 1))
            echo "  ⚠️  Worker '$w' is STALLED on modal: $modal"
            echo "     Active command: ${cmd:-idle}"
            echo "     Recent pane output:"
            quintet_window_capture "$name" "$w" 6 2>/dev/null | sed 's/^/       | /'
            echo "     Remediation: Attach to resolve: tmux attach -t $(quintet_tmux_session "$name")"
            echo "                  Or inject answer: quintet team send \"$name\" \"$w\" \"y\" --force"
        else
            echo "  ✅ Worker '$w': no recognized modal (running: ${cmd:-idle})"
        fi
    done < <(quintet_window_list "$name")

    # Compare live windows with the manifest: report workers that vanished or
    # appeared outside quintet.
    local expected
    if expected="$(_quintet_manifest_workers "$name")"; then
        local e
        while IFS= read -r e; do
            [[ -z "$e" ]] && continue
            printf '%s\n' "${windows[@]}" | grep -Fxq -- "$e" || { issues=$((issues + 1)); echo "  ❌ Worker '$e' is in team.json but has no window (missing)"; }
        done <<< "$expected"
        for w in "${windows[@]}"; do
            printf '%s\n' "$expected" | grep -Fxq -- "$w" || { issues=$((issues + 1)); echo "  ⚠️  Window '$w' is not in team.json (extra)"; }
        done
    else
        echo "  (manifest check skipped: no team.json or jq)"
    fi

    if [[ $issues -eq 0 ]]; then
        echo "==> No exited workers, no recognized modal stalls, and workers match the manifest (heuristic: unknown prompts are not detected)."
        return 0
    else
        echo "==> Total issues detected: $issues"
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

# quintet_team_send <name> <worker> <text> [--force] — refuses while the worker
# shows a recognized modal (the Enter would answer it) unless --force.
quintet_team_send() {
    local force=false a modal
    local -a pos=()
    for a in "$@"; do
        if [[ "$a" == --force ]]; then force=true; else pos+=( "$a" ); fi
    done
    local name="${pos[0]:-}" worker="${pos[1]:-}" text="${pos[2]:-}"
    [[ -n "$name" && -n "$worker" && -n "$text" && ${#pos[@]} -eq 3 ]] || die "usage: quintet team send <name> <worker> <text> [--force]"
    quintet_validate_team_name "$name"
    quintet_session_exists "$name" || die "team '$name' is not running"
    if [[ "$force" != true ]] && modal="$(_quintet_detect_worker_modal "$name" "$worker")"; then
        die "team send: ${worker} shows a modal (${modal}); the Enter after your text would answer it. Attach (tmux attach -t $(quintet_tmux_session "$name")) or re-run with --force to answer it on purpose"
    fi
    quintet_window_send "$name" "$worker" "$text" \
        || die "team send: no worker window '$worker' in team '$name' (worker names are exact; see: quintet team status $name)"
    log INFO "sent to ${name}/${worker}"
}

quintet_team_shutdown() {
    local name="${1:-}" force="${2:-}"
    [[ -n "$name" ]] || die "team shutdown: missing team name"
    quintet_validate_team_name "$name"
    local purge=false
    if [[ "$force" == "--force" || "$force" == "-f" ]]; then
        purge=true
        quintet_state_guard "$name"   # never rm through a symlinked state path (S-H1)
    fi
    if ! quintet_session_exists "$name"; then
        log WARN "team '$name' has no live session; cleaning state only"
    fi
    quintet_session_kill "$name"
    if [[ "$purge" == "true" ]]; then
        local tdir; tdir="$(_quintet_team_dir "$name")"
        if [[ -e "$tdir" ]] && ! quintet_safe_rm_dir "$tdir" "${QUINTET_STATE_DIR%/}/teams"; then
            die "team '$name' shut down, but state not purged: $tdir is not a removable team dir (must be a real, user-owned dir directly under ${QUINTET_STATE_DIR%/}/teams)"
        fi
        log INFO "team '$name' shut down and state purged"
    else
        log INFO "team '$name' shut down (state kept under $(_quintet_team_dir "$name"))"
    fi
}

quintet_team_list() {
    qtmux list-sessions -F '#{session_name}' 2>/dev/null \
        | grep '^quintet-' | sed 's/^quintet-/  • /' || echo "  (no quintet teams running)"
}
