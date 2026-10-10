#!/usr/bin/env bash
# quintet/lib/handoff.sh — two-phase review-to-team handoff automation.
#
# Bridges the gap between one-shot fleet review findings and worker teams.
# Ingests JSON output from `quintet review --json`, groups actionable findings
# by target file to ensure disjoint file ownership, partitions them across
# worker seats, and generates/launches the corresponding team or worktree command.
# ─────────────────────────────────────────────────────────────────────────────

if ! declare -f _quintet_parse_spec >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "${QUINTET_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/team.sh"
fi

# quintet_handoff_review <json_input_or_dash> [options]
# Options:
#   --spec <spec>         Target worker spec (default: "1:codex:implementer,1:claude:implementer")
#   --mode <team|worktrees> Target runtime mode (default: team)
#   --name <slug>         Team name (default: fix-review-<timestamp>)
#   --min-severity <high|med|low> Minimum severity threshold (default: med)
#   --run                 Execute the command immediately instead of just printing it
quintet_handoff_review() {
    local input_src="" spec="1:codex:implementer,1:claude:implementer" mode="team"
    local name="" min_sev="med" do_run=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -)              [[ -z "$input_src" ]] && input_src="$1" || die "handoff review: unexpected arg '$1'"; shift ;;
            --spec)         need_arg "$1" $#; spec="$2"; shift 2 ;;
            --mode)         need_arg "$1" $#; mode="$2"; shift 2 ;;
            --pipeline)     mode="pipeline"; shift ;;
            --name)         need_arg "$1" $#; name="$2"; shift 2 ;;
            --min-severity) need_arg "$1" $#; min_sev="$2"; shift 2 ;;
            --run)          do_run=true; shift ;;
            -*)             die "handoff review: unknown option '$1'" ;;
            *)              [[ -z "$input_src" ]] && input_src="$1" || die "handoff review: unexpected arg '$1'"; shift ;;
        esac
    done

    [[ -n "$input_src" ]] || die "handoff review: missing JSON review source (file path or '-')"

    local raw_json=""
    if [[ "$input_src" == "-" ]]; then
        raw_json="$(cat)"
    elif [[ -f "$input_src" ]]; then
        raw_json="$(cat "$input_src")"
    else
        die "handoff review: input file '$input_src' not found"
    fi

    [[ -n "$raw_json" ]] || die "handoff review: empty review input"

    if ! have_jq; then
        die "handoff review: jq is required to parse structured review findings"
    fi

    # Parse and filter findings by severity
    # Severity order: high > medium > low
    local jq_sev_filter
    case "$min_sev" in
        high) jq_sev_filter='["high"]' ;;
        med|medium) jq_sev_filter='["high", "medium"]' ;;
        low) jq_sev_filter='["high", "medium", "low"]' ;;
        *) die "handoff review: unknown min-severity '$min_sev' (use high, med, or low)" ;;
    esac

    # Extract deduplicated findings as TSV: file \t line \t severity \t message
    local -a findings=()
    mapfile -t findings < <(
        jq -r --argjson allowed "$jq_sev_filter" '
            [ .[] | select(.findings? != null) | .findings[]? | select(.file? != null and .file != "") ]
            | map(select(.severity as $s | $allowed | index($s | ascii_downcase)))
            | unique_by({file: .file, line: .line, message: .message})
            | sort_by(.file)
            | .[]
            | "\(.file)\t\(.line // 0)\t\(.severity // "med")\t\(.message // "")"
        ' <<< "$raw_json" 2>/dev/null
    )

    if [[ "${#findings[@]}" -eq 0 ]]; then
        echo "No actionable findings found matching severity threshold '$min_sev'."
        echo "No remediation team needed."
        return 0
    fi

    echo "Found ${#findings[@]} actionable findings across ${min_sev}+ severity:"
    local line f_file f_line f_sev f_msg
    for line in "${findings[@]}"; do
        IFS=$'\t' read -r f_file f_line f_sev f_msg <<< "$line"
        printf '  [%s] %s:%s — %s\n' "$f_sev" "$f_file" "$f_line" "$f_msg"
    done
    echo

    # Parse target workers from spec
    local -a workers=()
    mapfile -t workers < <(_quintet_parse_spec "$spec")
    local num_workers="${#workers[@]}"
    [[ "$num_workers" -gt 0 ]] || die "handoff review: invalid or empty spec '$spec'"

    # Group findings by file to maintain disjoint ownership
    local -A file_findings=()
    local -a unique_files=()
    for line in "${findings[@]}"; do
        IFS=$'\t' read -r f_file f_line f_sev f_msg <<< "$line"
        if [[ -z "${file_findings[$f_file]:-}" ]]; then
            unique_files+=( "$f_file" )
            file_findings[$f_file]="[$f_sev] $f_file:$f_line ($f_msg)"
        else
            file_findings[$f_file]="${file_findings[$f_file]}; [$f_sev] $f_file:$f_line ($f_msg)"
        fi
    done

    # Distribute unique files across workers (round-robin)
    local -a worker_tasks=()
    local i
    for ((i=0; i<num_workers; i++)); do
        worker_tasks[$i]=""
    done

    local w_idx=0 ufile
    for ufile in "${unique_files[@]}"; do
        if [[ -z "${worker_tasks[$w_idx]}" ]]; then
            worker_tasks[$w_idx]="Fix issues in ${file_findings[$ufile]}"
        else
            worker_tasks[$w_idx]="${worker_tasks[$w_idx]} and ${file_findings[$ufile]}"
        fi
        w_idx=$(( (w_idx + 1) % num_workers ))
    done

    # Build tasks argument string joined by '||'
    local tasks_arg=""
    for ((i=0; i<num_workers; i++)); do
        local t="${worker_tasks[$i]}"
        [[ -n "$t" ]] || t="Verify integration, review changes, and ensure tests pass"
        if [[ -z "$tasks_arg" ]]; then
            tasks_arg="$t"
        else
            tasks_arg="${tasks_arg}||${t}"
        fi
    done

    # Generate team name if not specified
    if [[ -z "$name" ]]; then
        name="fix-rev-$(date +%s | tail -c 6)"
    fi
    name="$(slugify "$name")"

    # Assemble CLI command
    local cmd_bin="${QBIN:-quintet}"
    local full_cmd
    if [[ "$mode" == "pipeline" ]]; then
        full_cmd=("$cmd_bin" pipeline init "$name" --template review-fix --goal "Fix review findings across ${#unique_files[@]} files")
    elif [[ "$mode" == "worktrees" ]]; then
        full_cmd=("$cmd_bin" worktrees "$spec" "Fix review findings across ${#unique_files[@]} files" --name "$name" --tasks "$tasks_arg")
    else
        full_cmd=("$cmd_bin" team "$spec" "Fix review findings across ${#unique_files[@]} files" --name "$name" --tasks "$tasks_arg")
    fi

    echo "=== Generated Remediation Command (${mode}) ==="
    printf '%q ' "${full_cmd[@]}"
    echo
    echo

    if [[ "$do_run" == true ]]; then
        echo "Executing remediation dispatch..."
        if [[ "$mode" == "pipeline" ]]; then
            local pdir="${QUINTET_STATE_DIR}/pipelines/${name}"
            quintet_pipeline_init "$name" --template review-fix --goal "Fix review findings across ${#unique_files[@]} files"
            echo "$raw_json" > "${pdir}/stages/01_review/output/findings.json"
            echo "✅ Review findings staged to ${pdir}/stages/01_review/output/findings.json"
            echo "Human Check Gate: inspect and edit findings before running: quintet pipeline advance ${name}"
        elif [[ "$mode" == "worktrees" ]]; then
            quintet_worktrees_start "$spec" "Fix review findings across ${#unique_files[@]} files" --name "$name" --tasks "$tasks_arg"
        else
            quintet_team_start "$spec" "Fix review findings across ${#unique_files[@]} files" --name "$name" --tasks "$tasks_arg"
        fi
    fi
}
