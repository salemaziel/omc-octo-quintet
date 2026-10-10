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

if ! declare -f quintet_icm_init_worker >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "${QUINTET_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/icm.sh"
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

# _quintet_team_abort_restore — undo this start's state changes. Runs from the
# EXIT/INT/TERM traps of quintet_team_start (the locals are gone by then, so it
# reads the _QT_* globals) until the start is committed. Removes the whole team
# dir if this start created it, else puts the prior taskboard.md back (R-L2).
# Disarms itself, so a second call (INT then EXIT) does nothing.
_quintet_team_abort_restore() {
    [[ -n "${_QT_TDIR:-}" ]] || return 0
    local tdir="$_QT_TDIR" new="$_QT_NEW" board="$_QT_BOARD" prev="$_QT_PREV"
    _QT_TDIR=""
    if [[ "$new" == true ]]; then
        quintet_safe_rm_dir "$tdir" "${QUINTET_STATE_DIR%/}/teams" || log WARN "team start: could not remove $tdir"
    elif [[ -n "$prev" ]]; then
        _quintet_rename "$prev" "$board" || log WARN "team start: could not restore $board"
    elif [[ "${_QT_WROTE:-false}" == true ]]; then
        rm -f -- "$board"
    fi
}

# quintet_team_start <spec> <task> [--cwd dir] [--name name] [--tasks "t1||t2||..."]
# --tasks lets the caller hand each worker a distinct, pre-decomposed subtask.
quintet_team_start() {
    quintet_tmux_available || die "tmux is not installed (required for team mode): see https://github.com/tmux/tmux"
    local spec="" task="" cwd="$PWD" name="" tasks_blob=""
    local skip_auth="${QUINTET_SKIP_AUTH_CHECK:-false}"
    local no_mcp="${QUINTET_NO_MCP:-false}"
    # --model/--effort: bare value = team-wide default, or provider=value[,...]
    # (resolved per worker by quintet_resolve_model/_effort, decision 3).
    local model_map="" model_bare="" effort_map="" effort_bare=""
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
            --model)            need_arg "$1" $#; quintet_parse_cli_value --model "$2" model_map model_bare; shift 2 ;;
            --effort)           need_arg "$1" $#; quintet_parse_cli_value --effort "$2" effort_map effort_bare; shift 2 ;;
            *) die "unknown team flag: $1" ;;
        esac
    done
    [[ -n "$spec" ]] || die "team start: missing spec (e.g. 2:claude,1:qwen)"
    [[ -n "$task" ]] || die "team start: missing task description"
    [[ -d "$cwd" ]]  || die "team start: --cwd not a directory: $cwd"
    cwd="$(cd "$cwd" && pwd)"
    quintet_tmux_fmt_escape "$cwd" >/dev/null || die "team start: --cwd contains '#[', which tmux can't use literally: $cwd"

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
    local lrc=0; quintet_lock "$name" || lrc=$?
    [[ $lrc -eq 2 ]] && die "team start: quintet needs GNU mv or python3 for locks"
    [[ $lrc -eq 0 ]] || die "team start: team '$name' is locked by another quintet process (start or prune in progress). If none is running, remove the lock: rm -rf -- $(printf '%q' "$(quintet_lock_path "$name")")"
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
    # Armed from here until the start commits: any die/INT/TERM runs
    # _quintet_team_abort_restore through the traps below.
    _QT_TDIR="$tdir" _QT_NEW="$tdir_new" _QT_BOARD="${tdir}/taskboard.md" _QT_PREV="" _QT_WROTE=false
    local abort_cmd="_quintet_team_abort_restore"
    # shellcheck disable=SC2064  # expand now
    trap "$abort_cmd; $unlock_cmd" EXIT
    # shellcheck disable=SC2064
    trap "$abort_cmd; $unlock_cmd; exit 130" INT TERM
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
        _QT_PREV="$board_prev"
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
    _QT_WROTE=true

    # Build manifest header.
    local manifest="${tdir}/team.json"
    local worker_json="" idx=1 started=0
    # Per-worker env files (A4): 0600 files in a private 0700 dir; each worker
    # deletes its own before exec. The trap removes leftovers on abort.
    local envdir
    envdir="$(mktemp -d "${TMPDIR:-/tmp}/quintet-env.XXXXXX")" || die "team start: cannot create env dir"
    chmod 700 "$envdir"
    # shellcheck disable=SC2064  # expand envdir now; the local is gone at EXIT
    trap "rm -rf -- $(printf '%q' "$envdir"); $abort_cmd; $unlock_cmd" EXIT
    # shellcheck disable=SC2064
    trap "rm -rf -- $(printf '%q' "$envdir"); $abort_cmd; $unlock_cmd; exit 130" INT TERM
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

        # Initialize ICM worker contract and filesystem state machine
        local contract_file
        contract_file="$(quintet_icm_init_worker "$tdir" "$worker_name" "$provider" "$role" "$task" "$wtask")"

        # The full instruction injected into the agent REPL.
        local injected
        injected="${role_block}You are ${worker_name}, a worker in quintet team '${name}' (role: ${role}). Working dir: ${cwd}. \
Shared team goal: ${task} \
Your assignment: ${wtask} \
Your full stage contract is at: ${contract_file} \
Coordinate by appending status to ${board} (one line, prefixed with [${worker_name}]). \
Avoid editing files another worker owns. When done, write 'done' to ${tdir}/workers/${worker_name}/status and a final [${worker_name}] DONE line to the taskboard."

        log INFO "spawning $worker_name ($(quintet_provider_emoji "$provider") $provider, role: $role)"
        local envf="${envdir}/${worker_name}.env"
        quintet_write_worker_env "$provider" "$envf" || die "team start: cannot write worker env file"
        quintet_window_spawn "$name" "$worker_name" "$cwd" "$(quintet_provider_launch_cmd "$provider" "$no_mcp" "$model" "$effort" "$safe_mode")" "$envf" || { log ERROR "worker $worker_name failed to start; skipping it (later workers keep their numbers)"; idx=$((idx+1)); continue; }
        started=$((started+1))
        echo "- **${worker_name}** ($provider, role: ${role}): ${wtask}" >> "$board"
        worker_json="${worker_json}${worker_json:+,}{\"name\": $(json_escape "${worker_name}"), \"provider\": $(json_escape "${provider}"), \"role\": $(json_escape "${role}"), \"model\": $(json_escape "${model:-default}"), \"effort\": $(json_escape "${effort:-default}"), \"no_mcp_effective\": $(json_escape "$mcp_eff")}"

        # The full instruction goes to an inbox file; the worker is told to read
        # it in one short line (multi-line text typed into a TUI can submit early).
        local kick inbox
        if inbox="$(_quintet_inbox_write "$cwd" "$name" "$worker_name" "$injected")"; then
            kick="Read and follow ${inbox} now."
        else
            log WARN "${worker_name}: cannot write the inbox file under ${cwd}/.quintet/inbox; typing the task instead"
            kick="$injected"
        fi

        # Defer task injection: warm up the REPL first, then send only if no
        # first-run dialog is showing (Enter would answer it, e.g. "No, exit").
        ( sleep "$(quintet_provider_warmup "$provider")"
          _quintet_team_kickoff "$name" "$worker_name" "$kick" ) &
        idx=$((idx+1))
    done

    # Zero workers started: don't leave a leader-only session behind (C-M3).
    # The EXIT trap restores the prior taskboard (or removes the team dir this
    # start created), removes the env dir and releases the lock. team.json isn't
    # written yet (R-L2).
    if [[ $started -eq 0 ]]; then
        quintet_session_kill "$name"
        die "team start: none of the ${#workers[@]} worker(s) started; session and this start's team state removed"
    fi
    _QT_TDIR=""   # committed: the traps no longer restore
    [[ -z "$board_prev" ]] || rm -f -- "$board_prev"

    local manifest_tmp
    manifest_tmp="$(mktemp "${tdir}/.team.json.XXXXXX")" || die "team start: cannot write ${manifest}"
    {
        printf '{\n'
        printf '  "name": %s,\n'    "$(json_escape "$name")"
        printf '  "cwd": %s,\n'     "$(json_escape "$cwd")"
        printf '  "session": %s,\n' "$(json_escape "$(quintet_tmux_session "$name")")"
        printf '  "tmux_socket": %s,\n' "$(json_escape "${QUINTET_TMUX_SOCKET:-default}")"
        printf '  "no_mcp": %s,\n'  "$no_mcp"
        printf '  "safe_mode": %s,\n' "$safe_mode"
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

    # Codex's hook-trust screen: "Hooks need review ... 3. Continue without
    # trusting ... Press enter to confirm or esc to go back". Enter there picks
    # whatever is highlighted, so it's held like the folder-trust dialog.
    if echo "$tail_buf" | grep -qi 'Hooks need review' && echo "$tail_buf" | grep -qi 'Continue without trusting'; then
        echo "HOOKS_REVIEW"
        return 0
    elif echo "$tail_buf" | grep -Ei 'do you trust this folder|trust folder|trust the authors|Is this a project you created or one you trust|Yes, I trust this folder|trust the files in this folder|trust the contents of this directory' >/dev/null 2>&1; then
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

# _quintet_worker_busy <team> <worker> — true if the pane shows a running turn:
# "esc to interrupt", or a spinner line with an elapsed counter, e.g. claude's
# "* Baking… (3s · thinking)" or codex's "• Working (2s • esc to interrupt)".
# The finished-turn lines ("✻ Brewed for 3s · done", "Worked for 21s • 2:44 PM")
# have no "(<n>s" and don't match.
_quintet_worker_busy() {
    local buf
    buf="$(quintet_window_capture "$1" "$2" 40 2>/dev/null)" || return 1
    printf '%s\n' "$buf" | grep -v '^[[:space:]]*$' | tail -n 15 \
        | grep -Eq 'esc to interrupt|^[[:space:]]*[^[:alnum:][:space:]]{1,4}[[:space:]]+[[:alpha:]][^()]*\([0-9]+[smh][^)]*[·•]'
}

# _quintet_inbox_write <cwd> <team> <file> <text> — write <text> to
# <cwd>/.quintet/inbox/<team>/<file>.md (0600; new dirs 0700; temp + rename so a
# planted symlink is replaced, not followed), add .quintet/ to the repo's
# .git/info/exclude, and print the path. Returns 1 if it can't.
_quintet_inbox_write() {
    local cwd="${1%/}" team="$2" file="$3" text="$4" d p tmp ex
    d="${cwd}/.quintet/inbox/${team}"
    for p in "${cwd}/.quintet" "${cwd}/.quintet/inbox" "$d"; do
        [[ -L "$p" ]] && { log ERROR "inbox: $p is a symlink; not writing there"; return 1; }
        [[ -d "$p" ]] || mkdir -m 700 "$p" 2>/dev/null || return 1
        [[ -O "$p" ]] || { log ERROR "inbox: $p is owned by another user; not writing there"; return 1; }
    done
    tmp="$(mktemp "${d}/.${file}.XXXXXX" 2>/dev/null)" || return 1
    if ! { printf '%s\n' "$text" > "$tmp" && chmod 600 "$tmp" && _quintet_rename "$tmp" "${d}/${file}.md"; }; then
        rm -f -- "$tmp"; return 1
    fi
    if ex="$(git -C "$cwd" rev-parse --git-path info/exclude 2>/dev/null)"; then
        [[ "$ex" == /* ]] || ex="${cwd}/${ex}"
        if [[ ! -L "$ex" ]] && ! grep -qxF '.quintet/' "$ex" 2>/dev/null; then
            mkdir -p -- "$(dirname -- "$ex")" 2>/dev/null && printf '.quintet/\n' >> "$ex"
        fi
    fi
    printf '%s\n' "${d}/${file}.md"
}

# _quintet_team_deliver <team> <worker> <text> [check] — type <text>, press
# Enter, and (check=true, the default) confirm it was submitted: the input line
# must no longer hold the text's tail. While it does, a dialog stops the retries
# (an Enter would answer it), a busy footer waits, otherwise Enter is pressed
# again, up to 3 times. The text is never retyped. Texts under 6 characters
# (e.g. "y") aren't checked: they'd match a placeholder.
# 0 sent; 1 no such window; 3 pane dead or in copy-mode; 4 still unsent after
# the retries; 5 a dialog is up with the text unsent.
_quintet_team_deliver() {
    local team="$1" worker="$2" text="$3" check="${4:-true}" st tail line tries=0 waits=0
    local delay="${QUINTET_SUBMIT_CHECK_DELAY:-0.8}"
    st="$(quintet_window_state "$team" "$worker")" || return 1
    [[ "$st" == "0 0" ]] || return 3
    quintet_window_type "$team" "$worker" "$text" || return 1
    sleep 0.4
    quintet_window_key "$team" "$worker" Enter || return 1
    tail="${text//[[:space:]]/}"; tail="${tail: -8}"
    [[ "$check" == true && ${#tail} -ge 6 ]] || return 0
    while :; do
        sleep "$delay"
        line="$(quintet_window_input_line "$team" "$worker")" || return 1
        [[ "${line//[[:space:]]/}" == *"$tail"* ]] || return 0
        _quintet_detect_worker_modal "$team" "$worker" >/dev/null && return 5
        if _quintet_worker_busy "$team" "$worker" && (( waits < 10 )); then
            waits=$((waits + 1)); continue
        fi
        (( tries < 3 )) || return 4
        tries=$((tries + 1))
        quintet_window_key "$team" "$worker" Enter || return 1
    done
}

# _quintet_deliver_msg <rc> — text for a non-zero _quintet_team_deliver status.
_quintet_deliver_msg() {
    case "$1" in
        1) echo "no such worker window" ;;
        3) echo "the pane is dead or in copy-mode (press q in it to leave copy-mode)" ;;
        4) echo "typed, but still in the input line after 3 extra Enters" ;;
        5) echo "typed, but a dialog came up before it was submitted" ;;
        *) echo "send failed (status $1)" ;;
    esac
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

# _quintet_team_kickoff <team> <worker> <text> — wait for the pane to draw (up
# to ~20s), then send <text> unless a modal is showing; otherwise hold it.
_quintet_team_kickoff() {
    local team="$1" worker="$2" text="$3" buf modal rc i
    for ((i=0; i<40; i++)); do
        buf="$(quintet_window_capture "$team" "$worker" 40)" && [[ "$buf" == *[![:space:]]* ]] && break
        sleep 0.5
    done
    modal="$(_quintet_detect_worker_modal "$team" "$worker")"; rc=$?
    if [[ $rc -eq 1 ]]; then
        _quintet_team_deliver "$team" "$worker" "$text"; rc=$?
        [[ $rc -eq 0 ]] || log WARN "${worker} kickoff: $(_quintet_deliver_msg "$rc"). Check: quintet team capture ${team} ${worker}"
        return
    fi
    [[ $rc -eq 2 ]] && modal="INSPECTION_ERROR"
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
        _quintet_team_deliver "$name" "$w" "$text"; rc=$?
        if [[ $rc -eq 0 ]]; then
            rm -f -- "$f"
            log INFO "resumed ${name}/${w}"
        elif [[ $rc -eq 1 || $rc -eq 3 ]]; then
            log ERROR "team resume: $w: $(_quintet_deliver_msg "$rc"); task kept in $f"; failed=1
        else
            # Typed already: keeping the file would make the next resume retype it.
            rm -f -- "$f"
            log ERROR "team resume: $w: $(_quintet_deliver_msg "$rc"). Check: quintet team capture ${name} ${w}"; failed=1
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
    case "$(quintet_tmux_liveness "=$(quintet_tmux_session "$name")")" in
        gone)    log WARN "team '$name' is not running (no tmux session $(quintet_tmux_session "$name"))"; return 1 ;;
        unknown) echo "Team: $name   ⚠️  UNKNOWN: tmux didn't answer for session $(quintet_tmux_session "$name"); nothing assumed. Retry, or check: tmux ls"; return 1 ;;
    esac
    local tdir; tdir="$(_quintet_team_dir "$name")"
    echo "Team: $name   session: $(quintet_tmux_session "$name")"
    [[ -f "${tdir}/team.json" ]] && have_jq && \
        echo "Goal: $(jq -r '.goal' "${tdir}/team.json")"
    echo "Workers:"
    local w cmd modal rc dst bad=0
    local -a windows=()
    while IFS= read -r w; do
        [[ -z "$w" ]] && continue
        windows+=( "$w" )
        if [[ "$(quintet_tmux_liveness "=$(quintet_tmux_session "$name"):=$w")" == unknown ]]; then
            printf '  • %-18s ⚠️  UNKNOWN: tmux error reading this window\n' "$w"
            bad=1
            continue
        fi
        if dst="$(quintet_window_dead_status "$name" "$w")"; then
            printf '  • %-18s ❌ EXITED (status %s)\n' "$w" "$dst"
            bad=1
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
    # A manifest worker with no window is missing (same rule as doctor).
    local expected e
    if expected="$(_quintet_manifest_workers "$name")"; then
        while IFS= read -r e; do
            [[ -z "$e" ]] && continue
            printf '%s\n' "${windows[@]}" | grep -Fxq -- "$e" || { bad=1; printf '  • %-18s ❌ MISSING (in team.json, no window)\n' "$e"; }
        done <<< "$expected"
    fi
    if [[ -d "${tdir}/workers" ]]; then
        echo "Workers (Filesystem State Machine):"
        quintet_icm_list_workers_status "$tdir" || true
    fi
    if [[ -f "${tdir}/taskboard.md" ]]; then
        echo "Taskboard tail:"
        tail -8 "${tdir}/taskboard.md" | sed 's/^/    /'
    fi
    return "$bad"
}

quintet_team_doctor() {
    local name="${1:-}"; [[ -n "$name" ]] || die "team doctor: missing team name"
    quintet_validate_team_name "$name"
    case "$(quintet_tmux_liveness "=$(quintet_tmux_session "$name")")" in
        gone)    echo "❌ Team '$name' is not running (no tmux session $(quintet_tmux_session "$name"))"; return 1 ;;
        unknown) echo "⚠️  Team '$name': UNKNOWN: tmux didn't answer for session $(quintet_tmux_session "$name"); nothing assumed. Retry, or check: tmux ls"; return 1 ;;
    esac

    echo "==> Diagnosing team: $name (session: $(quintet_tmux_session "$name"))"
    local issues=0
    local w cmd modal rc dst
    local -a windows=()
    while IFS= read -r w; do
        [[ -z "$w" ]] && continue
        windows+=( "$w" )
        if [[ "$(quintet_tmux_liveness "=$(quintet_tmux_session "$name"):=$w")" == unknown ]]; then
            issues=$((issues + 1))
            echo "  ⚠️  Worker '$w': UNKNOWN (tmux error reading this window)"
            continue
        fi
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

# _quintet_team_cwd <team> <worker> — the team's working dir: team.json's cwd,
# else the worker pane's current path.
_quintet_team_cwd() {
    local f c=""; f="$(_quintet_team_dir "$1")/team.json"
    [[ -f "$f" ]] && have_jq && c="$(jq -r '.cwd // empty' "$f" 2>/dev/null)"
    [[ -n "$c" ]] || c="$(qtmux display-message -p -t "=$(quintet_tmux_session "$1"):=$2" '#{pane_current_path}' 2>/dev/null)"
    [[ -n "$c" && -d "$c" ]] && printf '%s\n' "$c"
}

# Text longer than this many bytes, or with a newline, goes to an inbox file and
# the worker gets a one-line nudge to read it.
QUINTET_SEND_INLINE_MAX="${QUINTET_SEND_INLINE_MAX:-300}"

# quintet_team_send <name> <worker> <text> [--force] [--busy-ok] — refuses while
# the worker shows a recognized modal (the Enter would answer it) unless --force,
# and while it is mid-turn unless --busy-ok.
quintet_team_send() {
    local force=false busy_ok=false a modal
    local -a pos=()
    for a in "$@"; do
        case "$a" in
            --force)   force=true ;;
            --busy-ok) busy_ok=true ;;
            *)         pos+=( "$a" ) ;;
        esac
    done
    local name="${pos[0]:-}" worker="${pos[1]:-}" text="${pos[2]:-}"
    [[ -n "$name" && -n "$worker" && -n "$text" && ${#pos[@]} -eq 3 ]] || die "usage: quintet team send <name> <worker> <text> [--force] [--busy-ok]"
    quintet_validate_team_name "$name"
    [[ "$worker" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || die "team send: invalid worker name '$worker'"
    quintet_session_exists "$name" || die "team '$name' is not running"
    quintet_window_state "$name" "$worker" >/dev/null \
        || die "team send: no worker window '$worker' in team '$name' (worker names are exact; see: quintet team status $name)"
    if [[ "$force" != true ]] && modal="$(_quintet_detect_worker_modal "$name" "$worker")"; then
        die "team send: ${worker} shows a modal (${modal}); the Enter after your text would answer it. Attach (tmux attach -t $(quintet_tmux_session "$name")) or re-run with --force to answer it on purpose"
    fi
    if [[ "$busy_ok" != true ]] && _quintet_worker_busy "$name" "$worker"; then
        die "team send: ${worker} is mid-turn; wait for it to finish, or re-run with --busy-ok to type now (the CLI may queue it)"
    fi
    local msg="$text" cwd path rc
    if [[ "$force" != true && ( "$text" == *$'\n'* || ${#text} -gt $QUINTET_SEND_INLINE_MAX ) ]]; then
        cwd="$(_quintet_team_cwd "$name" "$worker")" || die "team send: can't find the team's working dir for the inbox file"
        path="$(_quintet_inbox_write "$cwd" "$name" "${worker}-$(date +%s)-$$" "$text")" || die "team send: cannot write the inbox file under ${cwd}/.quintet/inbox"
        msg="Read and follow ${path} now."
    fi
    if [[ "$force" == true ]]; then _quintet_team_deliver "$name" "$worker" "$msg" false; else _quintet_team_deliver "$name" "$worker" "$msg"; fi
    rc=$?
    [[ $rc -eq 0 ]] || die "team send: ${worker}: $(_quintet_deliver_msg "$rc")"
    log INFO "sent to ${name}/${worker}${path:+ (via $path)}"
}

# _quintet_team_graceful <name> <secs> — ask each live worker (no dialog up) to
# stop and write a STOPPED line on the taskboard, then wait at most <secs>
# seconds (counted from the first request) until each asked worker is done:
# it wrote a new STOPPED line, or exited, or was seen busy and has since been
# idle on two checks in a row. Idle alone isn't enough: a CLI can look idle
# before it has picked up the request. A worker showing a dialog is not done.
_quintet_team_graceful() {
    local name="$1" secs="$2" w modal rc end i base pending
    local board; board="$(_quintet_team_dir "$name")/taskboard.md"
    local sess; sess="$(quintet_tmux_session "$name")"
    local -a asked=() seen_busy=() quiet=() done_w=() warned=()
    base=0; [[ -f "$board" ]] && base="$(wc -l < "$board")"
    end=$(( $(now_epoch) + 10#$secs ))
    while IFS= read -r w; do
        [[ -n "$w" ]] || continue
        [[ "$(quintet_tmux_liveness "=${sess}:=${w}")" == alive ]] || continue
        if modal="$(_quintet_detect_worker_modal "$name" "$w")"; then
            log WARN "graceful: ${w} shows a dialog (${modal}); not asking it to stop"; continue
        fi
        _quintet_team_deliver "$name" "$w" "Stop now: finish or undo the edit you are in, add one line '[${w}] STOPPED: <where you got to>' to ${board}, then do nothing else."; rc=$?
        [[ $rc -eq 0 ]] || { log WARN "graceful: ${w}: $(_quintet_deliver_msg "$rc")"; continue; }
        asked+=( "$w" )
    done < <(quintet_window_list "$name")
    [[ ${#asked[@]} -ge 1 ]] || { log WARN "graceful: no worker could be asked to stop"; return 0; }
    log INFO "graceful: asked ${#asked[@]} worker(s) to stop; waiting up to ${secs}s"
    local new=""
    while (( $(now_epoch) < end )); do
        sleep 2
        new=""; [[ -f "$board" ]] && new="$(tail -n "+$((base + 1))" "$board" 2>/dev/null)"
        pending=0
        for i in "${!asked[@]}"; do
            [[ -n "${done_w[i]:-}" ]] && continue
            w="${asked[i]}"
            if grep -qF "[${w}] STOPPED" <<< "$new" || [[ "$(quintet_tmux_liveness "=${sess}:=${w}")" != alive ]]; then
                done_w[i]=1; continue
            fi
            if modal="$(_quintet_detect_worker_modal "$name" "$w")"; then
                [[ -n "${warned[i]:-}" ]] || log WARN "graceful: ${w} is showing a dialog (${modal}); it can't finish until that is answered"
                warned[i]=1; quiet[i]=0; pending=1; continue
            fi
            if _quintet_worker_busy "$name" "$w"; then
                seen_busy[i]=1; quiet[i]=0
            else
                quiet[i]=$(( ${quiet[i]:-0} + 1 ))
                [[ -n "${seen_busy[i]:-}" ]] && (( quiet[i] >= 2 )) && { done_w[i]=1; continue; }
            fi
            pending=1
        done
        (( pending )) || break
    done
    local stopped
    stopped="$(grep -F '] STOPPED' <<< "$new" | grep -cF -f <(printf '[%s] STOPPED\n' "${asked[@]}"))"
    log INFO "graceful: ${stopped:-0} of ${#asked[@]} worker(s) wrote a STOPPED line"
    grep -F -f <(printf '[%s] STOPPED\n' "${asked[@]}") <<< "$new" | sed 's/^/    /' >&2
    return 0
}

quintet_team_shutdown() {
    local name="" a purge=false graceful=""
    for a in "$@"; do
        case "$a" in
            --force|-f)   purge=true ;;
            --graceful)   graceful=30 ;;
            --graceful=*) graceful="${a#--graceful=}"
                          [[ "$graceful" =~ ^[0-9]+$ ]] || die "team shutdown: --graceful=N needs whole seconds (got '$graceful')" ;;
            -*)           die "team shutdown: unknown flag: $a" ;;
            *)            [[ -z "$name" ]] || die "usage: quintet team shutdown <name> [--force] [--graceful[=N]]"; name="$a" ;;
        esac
    done
    [[ -n "$name" ]] || die "team shutdown: missing team name"
    quintet_validate_team_name "$name"
    [[ "$purge" == true ]] && quintet_state_guard "$name"   # never rm through a symlinked state path (S-H1)
    if ! quintet_session_exists "$name"; then
        log WARN "team '$name' has no live session; cleaning state only"
    elif [[ -n "$graceful" ]]; then
        _quintet_team_graceful "$name" "$graceful"
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

# quintet_team_restart <name> <worker> [--force] — respawn one worker from
# team.json (same provider, model, effort, no-mcp, safe mode and cwd) and point
# it at its kickoff inbox file again. Refuses a worker whose CLI is still
# running unless --force; never acts when tmux can't say.
quintet_team_restart() {
    local force=false a
    local -a pos=()
    for a in "$@"; do
        case "$a" in
            --force|-f) force=true ;;
            -*)         die "team restart: unknown flag: $a" ;;
            *)          pos+=( "$a" ) ;;
        esac
    done
    local name="${pos[0]:-}" worker="${pos[1]:-}"
    [[ -n "$name" && -n "$worker" && ${#pos[@]} -eq 2 ]] || die "usage: quintet team restart <name> <worker> [--force]"
    quintet_validate_team_name "$name"
    [[ "$worker" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || die "team restart: invalid worker name '$worker'"
    quintet_session_exists "$name" || die "team '$name' is not running"
    quintet_state_guard "$name"
    have_jq || die "team restart: needs jq to read team.json"
    local tdir manifest entry; tdir="$(_quintet_team_dir "$name")"; manifest="${tdir}/team.json"
    [[ -f "$manifest" && ! -L "$manifest" ]] || die "team restart: no team.json for '$name'"
    entry="$(jq -c --arg w "$worker" '.workers[] | select(.name == $w)' "$manifest" 2>/dev/null)"
    [[ -n "$entry" ]] || die "team restart: '$worker' is not in team.json for '$name' (see: quintet team status $name)"

    local sess; sess="$(quintet_tmux_session "$name")"
    case "$(quintet_tmux_liveness "=${sess}:=${worker}")" in
        alive)   [[ "$force" == true ]] || die "team restart: ${worker} is still running; re-run with --force to replace it" ;;
        unknown) die "team restart: tmux didn't answer for ${worker}; nothing changed. Retry, or check: tmux ls" ;;
    esac

    local provider model effort cwd no_mcp safe_mode
    provider="$(jq -r '.provider' <<< "$entry")"
    model="$(jq -r '.model // "default"' <<< "$entry")";   [[ "$model" == default ]] && model=""
    effort="$(jq -r '.effort // "default"' <<< "$entry")"; [[ "$effort" == default ]] && effort=""
    cwd="$(jq -r '.cwd // empty' <<< "$entry")"
    [[ -n "$cwd" ]] || cwd="$(jq -r '.cwd // empty' "$manifest")"
    [[ -d "$cwd" ]] || die "team restart: the team's working dir is gone: ${cwd:-?}"
    no_mcp="$(jq -r '.no_mcp // false' "$manifest")"
    safe_mode="$(jq -r '.safe_mode // false' "$manifest")"
    quintet_provider_validate "$provider"

    local lrc=0; quintet_lock "$name" || lrc=$?
    [[ $lrc -eq 0 ]] || die "team restart: team '$name' is locked by another quintet process"
    local envdir
    envdir="$(mktemp -d "${TMPDIR:-/tmp}/quintet-env.XXXXXX")" || { quintet_unlock "$name"; die "team restart: cannot create env dir"; }
    chmod 700 "$envdir"
    # shellcheck disable=SC2064  # expand now
    trap "rm -rf -- $(printf '%q' "$envdir"); quintet_unlock $(printf '%q' "$name")" EXIT
    # shellcheck disable=SC2064
    trap "rm -rf -- $(printf '%q' "$envdir"); quintet_unlock $(printf '%q' "$name"); exit 130" INT TERM

    local envf="${envdir}/${worker}.env"
    quintet_write_worker_env "$provider" "$envf" || die "team restart: cannot write worker env file"
    qtmux kill-window -t "=${sess}:=${worker}" 2>/dev/null || true
    quintet_window_spawn "$name" "$worker" "$cwd" "$(quintet_provider_launch_cmd "$provider" "$no_mcp" "$model" "$effort" "$safe_mode")" "$envf" \
        || die "team restart: ${worker} failed to start"
    [[ -L "${tdir}/taskboard.md" ]] || echo "[quintet] ${worker} RESTARTED" >> "${tdir}/taskboard.md"

    local inbox="${cwd%/}/.quintet/inbox/${name}/${worker}.md"
    if [[ -f "$inbox" && ! -L "$inbox" ]]; then
        sleep "$(quintet_provider_warmup "$provider")"
        _quintet_team_kickoff "$name" "$worker" "Read and follow ${inbox} now."
    else
        log WARN "${worker}: no kickoff file at ${inbox}; started idle. Give it a task with: quintet team send ${name} ${worker} \"...\""
    fi
    local _w
    for _w in 1 2 3 4 5 6 7 8 9 10; do
        [[ -e "$envf" ]] || break
        sleep 0.5
    done
    rm -rf -- "$envdir"
    quintet_unlock "$name"
    trap - EXIT INT TERM
    log INFO "restarted ${name}/${worker}"
}

quintet_team_list() {
    qtmux list-sessions -F '#{session_name}' 2>/dev/null \
        | grep '^quintet-' | sed 's/^quintet-/  • /' || echo "  (no quintet teams running)"
}
