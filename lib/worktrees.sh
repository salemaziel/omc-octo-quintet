#!/usr/bin/env bash
# quintet/lib/worktrees.sh — headless worktree runtime.
#
# Dispatches parallel coding-agent workers headlessly into isolated git worktrees
# (one worktree per worker), each running non-interactively with auto-approve flags,
# avoiding REPL warmup stalls and write collisions. State lives under
# ${QUINTET_STATE_DIR}/worktrees/<name>/.
# ─────────────────────────────────────────────────────────────────────────────

if ! declare -f _quintet_parse_spec >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "${QUINTET_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/team.sh"
fi

_quintet_wt_state_dir() { echo "${QUINTET_STATE_DIR}/worktrees/$1"; }

# Check that the current directory is a clean/usable git worktree
_quintet_ensure_git_repo() {
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "worktrees: current directory is not a git repository"
}

# Construct the headless execution command for a worker inside its worktree
quintet_worktree_worker_cmd() {
    local provider="$1" brief_file="$2" wt_dir="$3"
    local no_mcp="${4:-${QUINTET_NO_MCP:-false}}"
    local model="${5:-}"
    local effort="${6:-}"
    local safe_mode="${7:-${QUINTET_SAFE_MODE:-false}}"

    local -a a=()
    case "$provider" in
        codex)
            a=(codex exec -C "$wt_dir")
            [[ "$safe_mode" != "true" ]] && a+=(-s workspace-write)
            [[ "$no_mcp" == "true" ]] && a+=(-c 'mcp_servers={}')
            [[ -n "$model" ]] && a+=(--model "$model")
            [[ -n "$effort" ]] && a+=(-c "model_reasoning_effort=${effort}")
            a+=(-)
            # Feed brief via stdin redirect
            printf 'cat %q | %s\n' "$brief_file" "$(printf '%q ' "${a[@]}")"
            return 0
            ;;
        agy|gemini)
            a=(agy -p "$(cat "$brief_file")")
            [[ "$safe_mode" != "true" ]] && a+=(--dangerously-skip-permissions)
            [[ -n "$model" ]] && a+=(--model "$model")
            [[ -n "$effort" ]] && a+=(--effort "$effort")
            ;;
        claude)
            a=(claude -p "$(cat "$brief_file")")
            [[ "$safe_mode" != "true" ]] && a+=(--permission-mode bypassPermissions)
            [[ "$no_mcp" == "true" ]] && a+=(--strict-mcp-config)
            [[ -n "$model" ]] && a+=(--model "$model")
            [[ -n "$effort" ]] && a+=(--effort "$effort")
            ;;
        copilot)
            a=(copilot -p "$(cat "$brief_file")")
            [[ "$safe_mode" != "true" ]] && a+=(--allow-all)
            [[ "$no_mcp" == "true" ]] && a+=(--disable-builtin-mcps)
            [[ -n "$model" ]] && a+=(--model "$model")
            [[ -n "$effort" ]] && a+=(--reasoning-effort "$effort")
            ;;
        qwen)
            a=(env GEMINI_CLI_TRUST_WORKSPACE=true QWEN_CLI_TRUST_WORKSPACE=true qwen -p "$(cat "$brief_file")")
            [[ "$safe_mode" != "true" ]] && a+=(--approval-mode yolo)
            [[ -n "$model" ]] && a+=(--model "$model")
            ;;
        opencode)
            a=(opencode run --pure)
            [[ "$safe_mode" != "true" ]] && a+=(--auto)
            [[ -n "$model" ]] && a+=(--model "$model")
            [[ -n "$effort" ]] && a+=(--variant "$effort")
            a+=("$(cat "$brief_file")")
            ;;
        *)
            die "worktrees: unsupported provider '$provider'"
            ;;
    esac
    printf '%s\n' "$(printf '%q ' "${a[@]}")"
}

# Start a headless worktree team:
#   quintet worktrees start <spec> "<task>" [--tasks "s1||s2"] [--base <ref>] [--name <name>] [--no-tmux]
quintet_worktrees_start() {
    _quintet_ensure_git_repo

    local spec="" task="" tasks_raw="" name="" base_ref="HEAD"
    local no_tmux=false no_mcp="${QUINTET_NO_MCP:-false}" safe_mode="${QUINTET_SAFE_MODE:-false}"
    local skip_auth=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tasks)     need_arg "$1" $#; tasks_raw="$2"; shift 2 ;;
            --name)      need_arg "$1" $#; name="$2"; shift 2 ;;
            --base)      need_arg "$1" $#; base_ref="$2"; shift 2 ;;
            --no-tmux)   no_tmux=true; shift ;;
            --tmux)      no_tmux=false; shift ;;
            --no-mcp)    no_mcp=true; shift ;;
            --safe)      safe_mode=true; shift ;;
            --skip-auth-check) skip_auth=true; shift ;;
            -*)          die "worktrees start: unknown option '$1'" ;;
            *)
                if [[ -z "$spec" ]]; then
                    spec="$1"
                elif [[ -z "$task" ]]; then
                    task="$1"
                else
                    die "worktrees start: unexpected argument '$1'"
                fi
                shift ;;
        esac
    done

    [[ -n "$spec" ]] || die "worktrees start: missing spec (e.g. 2:codex,1:claude)"
    [[ -n "$task" ]] || die "worktrees start: missing shared goal task description"

    local -a workers=()
    mapfile -t workers < <(_quintet_parse_spec "$spec")
    [[ "${#workers[@]}" -gt 0 ]] || die "worktrees start: empty worker spec"

    # Pre-flight readiness check
    if [[ "$skip_auth" != true && "${QUINTET_SKIP_AUTH_CHECK:-false}" != true ]]; then
        local w p r m
        for w in "${workers[@]}"; do
            IFS=':' read -r p r m <<< "$w"
            if ! quintet_provider_ready "$p"; then
                die "worktrees start: provider '$p' is not ready or unauthenticated. Run 'quintet doctor' for setup hints."
            fi
        done
    fi

    # Name generation
    if [[ -z "$name" ]]; then
        name="wt-$(date +%s | tail -c 6)"
    fi
    name="$(slugify "$name")"

    local sdir; sdir="$(_quintet_wt_state_dir "$name")"
    [[ ! -d "$sdir" ]] || die "worktrees start: team '$name' already exists (abort or merge first)"
    ensure_dir "$sdir"

    # Resolve base commit SHA
    local base_sha; base_sha="$(git rev-parse --verify "$base_ref" 2>/dev/null)" || die "worktrees start: invalid base ref '$base_ref'"

    # Subtasks
    local -a subtasks=()
    if [[ -n "$tasks_raw" ]]; then
        IFS='|' read -ra subtasks <<< "${tasks_raw//||/|}"
    fi

    # Check tmux availability
    if [[ "$no_tmux" != true ]] && ! quintet_tmux_available; then
        log WARN "worktrees: tmux not available; falling back to background subshells"
        no_tmux=true
    fi

    local sess="quintet-wt-${name}"
    if [[ "$no_tmux" != true ]]; then
        tmux new-session -d -s "$sess" -n "leader"
        tmux set-option -w -t "=$sess:=leader" remain-on-exit on
        echo "Worktree team tmux session: tmux attach -t $sess"
    fi

    local -a worker_records=()
    local idx=0 w_tok prov role model wname wbranch wdir brief_file wtask cmd
    local repo_root; repo_root="$(git rev-parse --show-toplevel)"

    for w_tok in "${workers[@]}"; do
        idx=$((idx + 1))
        IFS=':' read -r prov role model <<< "$w_tok"
        [[ -z "$role" ]] && role="stock"
        wname="w${idx}-${prov}"
        [[ "$role" != "stock" ]] && wname="${wname}-${role}"
        wbranch="quintet/${name}/${wname}"
        wdir="${repo_root}/.worktrees/${name}/${wname}"

        # Assign subtask
        wtask="$task"
        if [[ "${#subtasks[@]}" -ge "$idx" ]]; then
            wtask="${subtasks[$((idx - 1))]}"
        fi

        log INFO "creating worktree for $wname ($prov, role: $role) at .worktrees/${name}/${wname}"
        ensure_parent "$wdir"
        git worktree add -b "$wbranch" "$wdir" "$base_sha" >/dev/null 2>&1 || die "failed to create git worktree at $wdir"

        # Exclude worker scaffolding from git tracking
        local exclude_file="${repo_root}/.git/info/exclude"
        if [[ -f "$exclude_file" ]]; then
            for ef in ".brief.txt" ".agent.log" ".agent.pid" ".run.sh" ".exit_code"; do
                grep -qxF "$ef" "$exclude_file" 2>/dev/null || echo "$ef" >> "$exclude_file"
            done
        fi

        # Prepare brief file
        brief_file="${wdir}/.brief.txt"
        {
            echo "# Work Assignment for $wname"
            echo "Team: $name"
            echo "Shared Goal: $task"
            echo "Your Assignment: $wtask"
            echo
            if [[ "$role" != "stock" ]]; then
                echo "## Role Instructions"
                quintet_role_prompt "$role"
                echo
            fi
            echo "## Instructions"
            echo "1. Implement your assigned changes in this isolated worktree."
            echo "2. Do not touch or edit files outside your assignment scope."
            echo "3. When changes are complete, ensure code compiles/passes checks."
        } > "$brief_file"

        # Formulate execution command
        cmd="$(quintet_worktree_worker_cmd "$prov" ".brief.txt" "$wdir" "$no_mcp" "$model" "" "$safe_mode")"

        if [[ "$no_tmux" != true ]]; then
            local run_script="${wdir}/.run.sh"
            printf '#!/usr/bin/env bash\ncd %q || exit 1\necho "[%s] starting..."\n%s 2>&1 | tee .agent.log\nrc=$?\necho "[%s] finished with exit code $rc"\nexit $rc\n' \
                "$wdir" "$wname" "$cmd" "$wname" > "$run_script"
            chmod +x "$run_script"

            tmux new-window -t "=$sess" -n "$wname" -c "$wdir" "$run_script"
            tmux set-option -w -t "=$sess:=$wname" remain-on-exit on
        else
            (
                cd "$wdir" || exit 1
                eval "$cmd" > .agent.log 2>&1
                echo $? > .exit_code
            ) &
            echo $! > "${wdir}/.agent.pid"
        fi

        worker_records+=( "{\"name\":\"$wname\",\"provider\":\"$prov\",\"role\":\"$role\",\"model\":\"$model\",\"branch\":\"$wbranch\",\"path\":\"$wdir\",\"task\":\"$wtask\"}" )
    done

    # Save metadata
    {
        echo "{"
        echo "  \"team\": \"$name\","
        echo "  \"base_sha\": \"$base_sha\","
        echo "  \"created_at\": $(date +%s),"
        echo "  \"no_tmux\": $no_tmux,"
        echo "  \"workers\": ["
        local j; for ((j=0; j<${#worker_records[@]}; j++)); do
            echo -n "    ${worker_records[$j]}"
            [[ $((j + 1)) -lt ${#worker_records[@]} ]] && echo "," || echo ""
        done
        echo "  ]"
        echo "}"
    } > "${sdir}/worktrees.json"

    echo
    echo "✓ Worktree team '$name' initialized with ${#workers[@]} workers"
    echo "  Base SHA: ${base_sha:0:8}"
    echo "  Status check: quintet worktrees status $name"
    echo "  Integrate:    quintet worktrees merge $name"
    echo "  Abort:        quintet worktrees abort $name"
}

# Status of a running worktree team
quintet_worktrees_status() {
    _quintet_ensure_git_repo
    local name="${1:-}"
    [[ -n "$name" ]] || die "worktrees status: missing team name"
    local sdir; sdir="$(_quintet_wt_state_dir "$name")"
    [[ -f "${sdir}/worktrees.json" ]] || die "worktrees status: team '$name' not found"

    echo "Worktree Team: $name"
    printf '%-20s %-12s %-10s %-12s %s\n' "WORKER" "PROVIDER" "ROLE" "CHANGES" "STATUS"
    printf '%-20s %-12s %-10s %-12s %s\n' "--------------------" "------------" "----------" "------------" "------"

    local repo_root; repo_root="$(git rev-parse --show-toplevel)"
    local wdirs; wdirs=$(find "${repo_root}/.worktrees/${name}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    local wdir wname prov role chg st

    for wdir in $wdirs; do
        wname="$(basename "$wdir")"
        if [[ -d "$wdir" ]]; then
            chg="$(cd "$wdir" && git status --porcelain 2>/dev/null | wc -l)"
            if [[ -f "${wdir}/.agent.pid" ]]; then
                if kill -0 "$(cat "${wdir}/.agent.pid" 2>/dev/null)" 2>/dev/null; then
                    st="running (pid $(cat "${wdir}/.agent.pid"))"
                else
                    st="done (exit $(cat "${wdir}/.exit_code" 2>/dev/null || echo 0))"
                fi
            elif quintet_tmux_available && tmux has-session -t "quintet-wt-${name}" 2>/dev/null; then
                st="tmux pane"
            else
                st="idle"
            fi
            printf '%-20s %-12s %-10s %-12s %s\n' "$wname" "-" "-" "${chg} files" "$st"
        fi
    done
}

# Merge completed worktrees into an integration branch or target branch
quintet_worktrees_merge() {
    _quintet_ensure_git_repo
    local name="" target_branch=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --branch) need_arg "$1" $#; target_branch="$2"; shift 2 ;;
            -*)       die "worktrees merge: unknown option '$1'" ;;
            *)        [[ -z "$name" ]] && name="$1" || die "worktrees merge: unexpected arg '$1'"; shift ;;
        esac
    done
    [[ -n "$name" ]] || die "worktrees merge: missing team name"

    local sdir; sdir="$(_quintet_wt_state_dir "$name")"
    [[ -f "${sdir}/worktrees.json" ]] || die "worktrees merge: team '$name' not found"

    local repo_root; repo_root="$(git rev-parse --show-toplevel)"
    local wt_root="${repo_root}/.worktrees/${name}"
    [[ -d "$wt_root" ]] || die "worktrees merge: worktree directory $wt_root missing"

    # Default integration branch
    [[ -n "$target_branch" ]] || target_branch="quintet-integration-${name}"

    log INFO "committing any outstanding worker edits..."
    local wdir wname
    local -a branches=()
    for wdir in "${wt_root}"/*; do
        [[ -d "$wdir" ]] || continue
        wname="$(basename "$wdir")"
        (
            cd "$wdir" || exit 1
            git rm -f --cached .brief.txt .agent.log .agent.pid .run.sh .exit_code 2>/dev/null || true
            rm -f -- .brief.txt .agent.log .agent.pid .run.sh .exit_code
            if [[ -n "$(git status --porcelain)" ]]; then
                git add -A
                git commit -m "quintet($name): edits from worker $wname" >/dev/null 2>&1
            fi
        )
        branches+=( "quintet/${name}/${wname}" )
    done

    # Switch/checkout integration branch
    log INFO "merging worker branches into $target_branch..."
    git checkout -B "$target_branch" >/dev/null 2>&1 || die "failed to checkout $target_branch"

    local br rc=0
    for br in "${branches[@]}"; do
        log INFO "merging $br..."
        if ! git merge --no-edit "$br" >/dev/null 2>&1; then
            log WARN "conflict detected while merging $br. Resolve conflicts manually in $target_branch."
            rc=1
            break
        fi
    done

    if [[ "$rc" -eq 0 ]]; then
        echo "✓ All worker branches merged cleanly into '$target_branch'"
        echo "Cleaning up worktrees..."
        quintet_worktrees_abort "$name" --keep-branches
        echo "Integration branch ready: git checkout $target_branch"
    else
        echo "⚠️ Merge required manual intervention. Worktrees preserved for conflict resolution."
    fi
}

# Abort and clean up worktrees and tmux session
quintet_worktrees_abort() {
    _quintet_ensure_git_repo
    local name="" keep_branches=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --keep-branches) keep_branches=true; shift ;;
            *) [[ -z "$name" ]] && name="$1"; shift ;;
        esac
    done
    [[ -n "$name" ]] || die "worktrees abort: missing team name"

    # Terminate tmux session if running
    local sess="quintet-wt-${name}"
    if quintet_tmux_available && tmux has-session -t "$sess" 2>/dev/null; then
        tmux kill-session -t "$sess" >/dev/null 2>&1 || true
    fi

    # Prune and remove git worktrees
    local repo_root; repo_root="$(git rev-parse --show-toplevel)"
    local wt_root="${repo_root}/.worktrees/${name}"
    if [[ -d "$wt_root" ]]; then
        local wdir
        for wdir in "${wt_root}"/*; do
            [[ -d "$wdir" ]] || continue
            git worktree remove --force "$wdir" >/dev/null 2>&1 || rm -rf "$wdir"
        done
        rm -rf "$wt_root"
    fi
    git worktree prune >/dev/null 2>&1 || true

    # Delete branches unless requested
    if [[ "$keep_branches" != true ]]; then
        local br
        for br in $(git branch --list "quintet/${name}/*" | tr -d ' *'); do
            git branch -D "$br" >/dev/null 2>&1 || true
        done
    fi

    # Remove state dir
    rm -rf "$(_quintet_wt_state_dir "$name")"
    echo "✓ Worktree team '$name' aborted and cleaned up"
}

# List active worktree teams
quintet_worktrees_list() {
    local base="${QUINTET_STATE_DIR}/worktrees"
    [[ -d "$base" ]] || { echo "No active worktree teams."; return 0; }
    local t
    for t in "$base"/*; do
        [[ -d "$t" ]] && basename "$t"
    done
}
