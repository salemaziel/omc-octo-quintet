#!/usr/bin/env bash
# quintet/lib/icm.sh — Interpretable Context Methodology (ICM) runtime for Quintet.
#
# Implements ICM architectural principles (Van Clief & McDermott, arXiv:2603.16021):
# 1. Numbered staged folder pipelines with human check gates
# 2. Explicit L2 folder contracts (CONTEXT.md with Inputs, Process, Outputs, Human Check)
# 3. Filesystem-as-state-machine per worker (workers/<w>/status, workers/<w>/output/)
# 4. Layered context loading and token discipline (2,000–8,000 token budget)
# 5. Cold-agent Walk Test diagnostics (quintet walk <team|pipeline|dir>)
# ─────────────────────────────────────────────────────────────────────────────

if ! declare -f slugify >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "${QUINTET_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/common.sh"
fi

_quintet_pipelines_dir() {
    echo "${QUINTET_STATE_DIR}/pipelines"
}

# ── 1. Worker Contract Generation (L2 Stage Contract) ────────────────────────
# quintet_icm_write_worker_contract <file> <worker> <provider> <role> <goal> <subtask> \
#                                   <status_file> <output_dir> [target_files] [inputs]
quintet_icm_write_worker_contract() {
    local cfile="$1" worker="$2" provider="$3" role="$4" goal="$5" subtask="$6"
    local status_file="$7" output_dir="$8"
    local target_files="${9:-"Files required for: ${subtask}"}"
    local working_inputs="${10:-"Subtask description: ${subtask}"}"

    local role_path=""
    local skills=""
    if declare -f quintet_role_file >/dev/null 2>&1; then
        role_path="$(quintet_role_file "$role" 2>/dev/null || true)"
    fi
    [[ -n "$role_path" ]] || role_path="Stock model baseline"
    if declare -f quintet_role_skills >/dev/null 2>&1; then
        skills="$(quintet_role_skills "$role" 2>/dev/null || true)"
    fi

    ensure_parent "$cfile"
    cat > "$cfile" <<EOF
# Worker Stage Contract: ${worker}

One job: ${subtask}

## Role & Provider
- **Worker**: ${worker}
- **Provider CLI**: ${provider}
- **Assigned Role**: ${role}
- **Team Goal**: ${goal}

## Recommended Skills & Disciplines
> **Advisory**: These skills represent recommended engineering/design disciplines for this role. If an enumerated skill is installed in your agent environment, invoke or reference it. If not installed (or if external helper scripts are not present in the workspace), embody the underlying methodology directly using standard repository tools without failing or stalling.
${skills:-"- None specified (operate under standard role guidelines)"}

## Inputs
- **Working (this run)**: ${working_inputs}
- **Reference (stable)**: ${role_path}
- **Reference (stable)**: Repository architecture, conventions, and test commands

## Process
1. Internalize assigned role constraints from reference instructions.
2. Review the working inputs and target files.
3. Implement the assigned subtask strictly within target files.
4. Verify changes locally using test/build suites.
5. Summarize work completed into '${output_dir}/summary.md'.
6. Write 'done' to '${status_file}'.

## Target Files & Boundaries
- **Target Files**: ${target_files}
- **Strict Constraint**: Never edit files outside your assignment scope without coordinator approval.

## Outputs
- Code modifications applied to workspace or worktree branch
- '${output_dir}/summary.md' (bulleted list of changes and test outcomes)
- '${status_file}' (set to 'done')

## Human Check
Inspect git diff for assigned files and verify local test commands pass before claiming completion.
EOF
}

# ── 2. Filesystem State Machine for Workers ─────────────────────────────────
# quintet_icm_init_worker <team_dir> <worker> <provider> <role> <goal> <subtask> [targets] [inputs]
quintet_icm_init_worker() {
    local tdir="$1" worker="$2" provider="$3" role="$4" goal="$5" subtask="$6"
    local targets="${7:-}" inputs="${8:-}"

    local wdir="${tdir}/workers/${worker}"
    local outdir="${wdir}/output"
    local status_file="${wdir}/status"
    local contract_file="${wdir}/CONTEXT.md"

    ensure_dir "$wdir"
    ensure_dir "$outdir"

    echo "working" > "$status_file"
    quintet_icm_write_worker_contract "$contract_file" "$worker" "$provider" "$role" \
        "$goal" "$subtask" "$status_file" "$outdir" "$targets" "$inputs"

    echo "$contract_file"
}

# quintet_icm_set_worker_status <team_dir> <worker> <status>
quintet_icm_set_worker_status() {
    local tdir="$1" worker="$2" status="$3"
    local sfile="${tdir}/workers/${worker}/status"
    ensure_parent "$sfile"
    echo "$status" > "$sfile"
}

# quintet_icm_get_worker_status <team_dir> <worker>
quintet_icm_get_worker_status() {
    local tdir="$1" worker="$2"
    local sfile="${tdir}/workers/${worker}/status"
    if [[ -f "$sfile" ]]; then
        cat "$sfile" | tr -d '[:space:]'
    else
        echo "unknown"
    fi
}

# quintet_icm_list_workers_status <team_dir>
quintet_icm_list_workers_status() {
    local tdir="$1"
    local wdirs
    wdirs=$(find "${tdir}/workers" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
    [[ -n "$wdirs" ]] || return 1

    local wdir wname st out_count
    for wdir in $wdirs; do
        wname="$(basename "$wdir")"
        st="$(quintet_icm_get_worker_status "$tdir" "$wname")"
        out_count="$(find "${wdir}/output" -type f 2>/dev/null | wc -l)"
        printf '  • %-20s [status: %-8s] (artifacts: %s)\n' "$wname" "$st" "$out_count"
    done
    return 0
}

# ── 3. The Walk Test (Cold-Agent Auditability) ────────────────────────────────
# quintet_walk <target_name_or_dir>
quintet_walk() {
    local target="${1:-}"
    [[ -n "$target" ]] || die "walk: missing team name, pipeline name, or directory"

    local root_dir=""
    local mode="unknown"

    if [[ -d "$target" ]]; then
        root_dir="$target"
        if [[ -f "${root_dir}/pipeline.json" ]]; then
            mode="pipeline"
        elif [[ -f "${root_dir}/team.json" ]]; then
            mode="team"
        elif [[ -f "${root_dir}/worktrees.json" ]]; then
            mode="worktrees"
        else
            mode="directory"
        fi
    elif [[ -d "${QUINTET_STATE_DIR}/teams/${target}" ]]; then
        root_dir="${QUINTET_STATE_DIR}/teams/${target}"
        mode="team"
    elif [[ -d "${QUINTET_STATE_DIR}/pipelines/${target}" ]]; then
        root_dir="${QUINTET_STATE_DIR}/pipelines/${target}"
        mode="pipeline"
    elif [[ -d "${QUINTET_STATE_DIR}/worktrees/${target}" ]]; then
        root_dir="${QUINTET_STATE_DIR}/worktrees/${target}"
        mode="worktrees"
    else
        die "walk: target '$target' not found as a directory, team, or pipeline"
    fi

    echo "=== ICM Walk Test: $(basename "$root_dir") (mode: $mode) ==="
    echo "Inspecting root: $root_dir"
    echo

    local pass=0 warn=0 fail=0

    # Test 1: L0/L1 Catalog & Manifest Check
    local manifest=""
    if [[ "$mode" == "team" && -f "${root_dir}/team.json" ]]; then
        manifest="${root_dir}/team.json"
    elif [[ "$mode" == "pipeline" && -f "${root_dir}/pipeline.json" ]]; then
        manifest="${root_dir}/pipeline.json"
    elif [[ "$mode" == "worktrees" && -f "${root_dir}/worktrees.json" ]]; then
        manifest="${root_dir}/worktrees.json"
    elif [[ -f "${root_dir}/CONTEXT.md" ]]; then
        manifest="${root_dir}/CONTEXT.md"
    fi

    if [[ -n "$manifest" ]]; then
        local lcnt; lcnt="$(wc -l < "$manifest")"
        if [[ "$lcnt" -le 100 ]]; then
            printf '  ✅ L0/L1 Catalog: %s exists (%d lines <= 100)\n' "$(basename "$manifest")" "$lcnt"
            pass=$((pass + 1))
        else
            printf '  ⚠️  L0/L1 Catalog: %s is bloated (%d lines > 100 lines)\n' "$(basename "$manifest")" "$lcnt"
            warn=$((warn + 1))
        fi
    else
        printf '  ❌ L0/L1 Catalog: missing root manifest / CONTEXT.md\n'
        fail=$((fail + 1))
    fi

    # Test 2: Stage & Worker Contracts Check
    local contracts=()
    mapfile -t contracts < <(find "$root_dir" -name "CONTEXT.md" 2>/dev/null)

    if [[ "${#contracts[@]}" -gt 0 ]]; then
        printf '  ✅ Contracts: found %d CONTEXT.md contracts across stages/workers\n' "${#contracts[@]}"
        pass=$((pass + 1))

        local c missing_sections
        for c in "${contracts[@]}"; do
            missing_sections=()
            grep -q "## Inputs" "$c" || missing_sections+=("Inputs")
            grep -q "## Process" "$c" || missing_sections+=("Process")
            grep -q "## Outputs" "$c" || missing_sections+=("Outputs")
            grep -q "## Human Check" "$c" || missing_sections+=("Human Check")

            local rel_c="${c#"$root_dir"/}"
            if [[ "${#missing_sections[@]}" -eq 0 ]]; then
                printf '     • %-30s [Inputs ✓ Process ✓ Outputs ✓ Human Check ✓]\n' "$rel_c"
            else
                printf '     • %-30s ⚠️  missing sections: %s\n' "$rel_c" "${missing_sections[*]}"
                warn=$((warn + 1))
            fi
        done
    else
        printf '  ❌ Contracts: no CONTEXT.md contracts found in target\n'
        fail=$((fail + 1))
    fi

    # Test 3: Filesystem State Machine Check
    if [[ "$mode" == "team" ]]; then
        if [[ -d "${root_dir}/workers" ]]; then
            local wcnt; wcnt="$(find "${root_dir}/workers" -mindepth 1 -maxdepth 1 -type d | wc -l)"
            local scnt; scnt="$(find "${root_dir}/workers" -name "status" | wc -l)"
            if [[ "$wcnt" -gt 0 && "$scnt" -eq "$wcnt" ]]; then
                printf '  ✅ State Machine: %d/%d workers have filesystem status files\n' "$scnt" "$wcnt"
                pass=$((pass + 1))
            else
                printf '  ⚠️  State Machine: %d workers, but only %d status files found\n' "$wcnt" "$scnt"
                warn=$((warn + 1))
            fi
        else
            printf '  ⚠️  State Machine: legacy team without workers/ state directory\n'
            warn=$((warn + 1))
        fi
    elif [[ "$mode" == "pipeline" ]]; then
        local stages=()
        mapfile -t stages < <(find "${root_dir}/stages" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
        if [[ "${#stages[@]}" -gt 0 ]]; then
            printf '  ✅ Pipeline Stages: %d numbered stages found\n' "${#stages[@]}"
            pass=$((pass + 1))
            local s sname sout
            for s in "${stages[@]}"; do
                sname="$(basename "$s")"
                sout="$(find "${s}/output" -type f 2>/dev/null | wc -l)"
                printf '     • %-24s (output artifacts: %d)\n' "$sname" "$sout"
            done
        else
            printf '  ❌ Pipeline Stages: no stage directories found under stages/\n'
            fail=$((fail + 1))
        fi
    fi

    # Test 4: Token Discipline Check (< 8,000 tokens / ~32KB per contract)
    local token_pass=true
    for c in "${contracts[@]}"; do
        local bsize; bsize="$(wc -c < "$c" 2>/dev/null || echo 0)"
        if [[ "$bsize" -gt 32768 ]]; then
            printf '  ⚠️  Token Discipline: %s exceeds 32 KB budget (%d bytes)\n' "${c#"$root_dir"/}" "$bsize"
            token_pass=false
            warn=$((warn + 1))
        fi
    done
    if [[ "$token_pass" == true && "${#contracts[@]}" -gt 0 ]]; then
        printf '  ✅ Token Discipline: all contracts well within 2,000–8,000 token envelope\n'
        pass=$((pass + 1))
    fi

    echo
    echo "Walk Test Summary: $pass passed, $warn warnings, $fail failures."
    if [[ $fail -eq 0 ]]; then
        echo "🎉 The workspace passed the ICM Walk Test. Cold agents can navigate it without blind guessing."
        return 0
    else
        echo "⚠️  The workspace has structural gaps. Fix the failing checks above to ensure cold-agent auditability."
        return 1
    fi
}

# ── 4. Staged Folder Pipelines (quintet pipeline) ───────────────────────────

# quintet_pipeline_init <name> [--template debate-build|review-fix] [--goal "<goal>"] [--dir DIR]
quintet_pipeline_init() {
    local name="" tmpl="debate-build" goal="" target_dir=""
    [[ $# -ge 1 ]] || die "pipeline init: missing pipeline name"
    name="$1"; shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --template) need_arg "$1" $#; tmpl="$2"; shift 2 ;;
            --goal)     need_arg "$1" $#; goal="$2"; shift 2 ;;
            --dir)      need_arg "$1" $#; target_dir="$2"; shift 2 ;;
            *) die "pipeline init: unknown argument '$1'" ;;
        esac
    done

    name="$(slugify "$name")"
    [[ -n "$target_dir" ]] || target_dir="$(_quintet_pipelines_dir)/${name}"
    [[ ! -d "$target_dir" ]] || die "pipeline init: pipeline directory '$target_dir' already exists"

    ensure_dir "$target_dir"
    ensure_dir "${target_dir}/stages"
    ensure_dir "${target_dir}/_shared"

    echo "Initializing ICM Pipeline '${name}' (template: ${tmpl}) at: ${target_dir}"

    case "$tmpl" in
        review-fix)
            # Stage 01: Multi-Model Review
            ensure_dir "${target_dir}/stages/01_review/output"
            cat > "${target_dir}/stages/01_review/CONTEXT.md" <<EOF
# 01_review — Multi-Model Fleet Code Review

One job: review the target diff or files across multiple provider CLIs.

## Inputs
- **Working (this run)**: target git diff or source files
- **Reference (stable)**: quintet review severity guidelines

## Process
1. Execute multi-model fleet review: 'quintet review "<target>" --json > output/findings.json'.
2. Record unparsed logs or observations in 'output/review_summary.md'.

## Outputs
- 'output/findings.json'
- 'output/review_summary.md'

## Human Check
Review 'findings.json' and edit in place: remove false positives, adjust severities, or add notes before advancing to triage.
EOF

            # Stage 02: Triage & Work Partitioning (Human Edit Surface)
            ensure_dir "${target_dir}/stages/02_triage/output"
            cat > "${target_dir}/stages/02_triage/CONTEXT.md" <<EOF
# 02_triage — Triage and Task Partitioning

One job: filter approved findings and partition them across worker seats.

## Inputs
- **Working (this run)**: ../01_review/output/findings.json
- **Reference (stable)**: _shared/roles.md

## Process
1. Ingest approved findings from Stage 01.
2. Group findings by file to guarantee disjoint worker boundaries.
3. Emit worker assignments into 'output/assignments.json'.

## Outputs
- 'output/assignments.json'

## Human Check
Inspect 'output/assignments.json' to confirm file ownership boundaries do not collide. Edit file assignments if needed.
EOF

            # Stage 03: Remediation Team
            ensure_dir "${target_dir}/stages/03_remediation/output"
            cat > "${target_dir}/stages/03_remediation/CONTEXT.md" <<EOF
# 03_remediation — Parallel Worker Team Remediation

One job: dispatch workers in headless worktrees or tmux to fix assigned findings.

## Inputs
- **Working (this run)**: ../02_triage/output/assignments.json
- **Reference (stable)**: Assigned worker role definitions

## Process
1. Spawn worktrees or team with disjoint assignments.
2. Monitor workers until completion.
3. Record modified commit SHAs into 'output/remediation.log'.

## Outputs
- Worker git branches / commits
- 'output/remediation.log'

## Human Check
Inspect git commits from each worker. Ensure changes compile and pass test suites.
EOF

            # Stage 04: Verification
            ensure_dir "${target_dir}/stages/04_verify/output"
            cat > "${target_dir}/stages/04_verify/CONTEXT.md" <<EOF
# 04_verify — Integration Verification & Merge

One job: run automated test suites on the integrated changes.

## Inputs
- **Working (this run)**: merged worker branch
- **Reference (stable)**: test suite command

## Process
1. Merge worker branches into integration candidate.
2. Run full test suite and linters.
3. Record test logs into 'output/test_results.log'.

## Outputs
- 'output/test_results.log'
- 'output/VERIFIED'

## Human Check
Review 'test_results.log'. If green, approve final PR or branch merge.
EOF
            ;;

        debate-build|*)
            # Stage 01: Multi-Model Debate
            ensure_dir "${target_dir}/stages/01_debate/output"
            cat > "${target_dir}/stages/01_debate/CONTEXT.md" <<EOF
# 01_debate — Cross-Model Architecture Debate

One job: debate architectural approaches across heterogeneous models.

## Inputs
- **Working (this run)**: Architecture question or problem statement: ${goal}
- **Reference (stable)**: _shared/architecture-principles.md

## Process
1. Run multi-model debate: 'quintet debate "<question>"'.
2. Record consensus points and disagreements in 'output/consensus.md'.

## Outputs
- 'output/consensus.md'
- 'output/divergence.md'

## Human Check
Read 'consensus.md' and edit chosen design direction. Downstream stages build whatever decision is recorded here.
EOF

            # Stage 02: Work Decomposition & Specification
            ensure_dir "${target_dir}/stages/02_spec/output"
            cat > "${target_dir}/stages/02_spec/CONTEXT.md" <<EOF
# 02_spec — Task Decomposition and Contract Generation

One job: decompose the chosen architecture into disjoint, file-scoped subtasks.

## Inputs
- **Working (this run)**: ../01_debate/output/consensus.md
- **Reference (stable)**: _shared/contracts-template.md

## Process
1. Break goal into non-overlapping subtasks (max 10).
2. Assign each subtask an optimal provider and expert role.
3. Output worker specs to 'output/spec.json' and 'output/spec.md'.

## Outputs
- 'output/spec.json'
- 'output/spec.md'

## Human Check
Verify subtasks have zero file overlap. Edit 'spec.json' directly if needed.
EOF

            # Stage 03: Parallel Implementation
            ensure_dir "${target_dir}/stages/03_implement/output"
            cat > "${target_dir}/stages/03_implement/CONTEXT.md" <<EOF
# 03_implement — Parallel Implementation (Worktrees or Team)

One job: execute subtasks in parallel using Quintet workers.

## Inputs
- **Working (this run)**: ../02_spec/output/spec.json
- **Reference (stable)**: Assigned worker roles

## Process
1. Launch workers via 'quintet worktrees start' or 'quintet team start'.
2. Monitor filesystem state machine until all workers report 'done'.
3. Output diffs and summary into 'output/implementation.md'.

## Outputs
- Git branches / workspace changes
- 'output/implementation.md'

## Human Check
Review git diff for each worker. Verify no unexpected files were touched.
EOF

            # Stage 04: Multi-Model Review
            ensure_dir "${target_dir}/stages/04_review/output"
            cat > "${target_dir}/stages/04_review/CONTEXT.md" <<EOF
# 04_review — Multi-Model Verification Review

One job: review implementation diffs for defects, edge cases, and regressions.

## Inputs
- **Working (this run)**: git diff of implemented changes
- **Reference (stable)**: Project quality standards

## Process
1. Run 'quintet review' on implementation diffs.
2. Output review findings to 'output/review_findings.json'.

## Outputs
- 'output/review_findings.json'
- 'output/review_summary.md'

## Human Check
Confirm all high/medium severity findings are resolved before final merge.
EOF
            ;;
    esac

    # Root Catalog / Routing File (L1)
    cat > "${target_dir}/CONTEXT.md" <<EOF
# Pipeline: ${name}

Interpretable Context Methodology (ICM) multi-stage pipeline.

## Metadata
- **Name**: ${name}
- **Template**: ${tmpl}
- **Goal**: ${goal:-"Unspecified goal"}
- **Created**: $(now_iso)

## Stages
1. **01_** — Initial debate or review discovery
2. **02_** — Triage, specification, and human gate
3. **03_** — Parallel implementation across Quintet workers
4. **04_** — Review and integration verification

## Rule
Every stage's output is an edit surface. Edit intermediate files in 'output/' before advancing to the next stage.
EOF

    # Pipeline manifest JSON
    cat > "${target_dir}/pipeline.json" <<EOF
{
  "name": $(json_escape "$name"),
  "template": $(json_escape "$tmpl"),
  "goal": $(json_escape "$goal"),
  "dir": $(json_escape "$target_dir"),
  "created": $(json_escape "$(now_iso)")
}
EOF

    echo "✅ Pipeline initialized. Inspect stages with: quintet pipeline status ${name}"
}

# quintet_pipeline_status <name_or_dir>
quintet_pipeline_status() {
    local target="${1:-}"
    [[ -n "$target" ]] || die "pipeline status: missing pipeline name or directory"

    local pdir=""
    if [[ -d "$target" && -f "${target}/pipeline.json" ]]; then
        pdir="$target"
    elif [[ -d "$(_quintet_pipelines_dir)/${target}" ]]; then
        pdir="$(_quintet_pipelines_dir)/${target}"
    else
        die "pipeline status: pipeline '$target' not found"
    fi

    local name tmpl goal
    name="$(have_jq && jq -r '.name // "unknown"' "${pdir}/pipeline.json" 2>/dev/null || basename "$pdir")"
    tmpl="$(have_jq && jq -r '.template // "unknown"' "${pdir}/pipeline.json" 2>/dev/null || echo "unknown")"
    goal="$(have_jq && jq -r '.goal // ""' "${pdir}/pipeline.json" 2>/dev/null || echo "")"

    echo "ICM Pipeline: ${name} (template: ${tmpl})"
    [[ -z "$goal" ]] || echo "Goal: ${goal}"
    echo "Directory: ${pdir}"
    echo
    printf '%-22s %-12s %s\n' "STAGE" "STATUS" "ARTIFACTS"
    printf '%-22s %-12s %s\n' "----------------------" "------------" "---------"

    local stages=()
    mapfile -t stages < <(find "${pdir}/stages" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

    local s sname out_cnt st
    for s in "${stages[@]}"; do
        sname="$(basename "$s")"
        out_cnt="$(find "${s}/output" -type f 2>/dev/null | wc -l)"
        if [[ "$out_cnt" -gt 0 ]]; then
            st="completed"
        else
            st="pending"
        fi
        printf '%-22s %-12s %s file(s)\n' "$sname" "$st" "$out_cnt"
    done
}

# quintet_pipeline_advance <name_or_dir> [--auto]
quintet_pipeline_advance() {
    local target="${1:-}"
    [[ -n "$target" ]] || die "pipeline advance: missing pipeline name or directory"
    shift
    local auto_advance=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --auto) auto_advance=true; shift ;;
            *) die "pipeline advance: unknown argument '$1'" ;;
        esac
    done

    local pdir=""
    if [[ -d "$target" && -f "${target}/pipeline.json" ]]; then
        pdir="$target"
    elif [[ -d "$(_quintet_pipelines_dir)/${target}" ]]; then
        pdir="$(_quintet_pipelines_dir)/${target}"
    else
        die "pipeline advance: pipeline '$target' not found"
    fi

    # Find the first pending stage
    local stages=()
    mapfile -t stages < <(find "${pdir}/stages" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
    local cur_stage="" prev_stage=""
    local s out_cnt

    for s in "${stages[@]}"; do
        out_cnt="$(find "${s}/output" -type f 2>/dev/null | wc -l)"
        if [[ "$out_cnt" -eq 0 ]]; then
            cur_stage="$s"
            break
        fi
        prev_stage="$s"
    done

    if [[ -z "$cur_stage" ]]; then
        echo "🎉 All pipeline stages are complete! Run 'quintet walk $(basename "$pdir")' to audit."
        return 0
    fi

    local cname; cname="$(basename "$cur_stage")"
    echo "Current active stage: ${cname}"

    if [[ -n "$prev_stage" && "$auto_advance" != true ]]; then
        local pname; pname="$(basename "$prev_stage")"
        echo "Human Check Gate: Stage '${pname}' produced output artifacts in '${prev_stage}/output/'."
        echo "You can inspect or edit these files before proceeding."
        echo "To confirm and proceed to '${cname}', run with --auto or execute stage instructions."
    fi

    echo "Stage Contract: ${cur_stage}/CONTEXT.md"
    if [[ -f "${cur_stage}/CONTEXT.md" ]]; then
        echo "---"
        cat "${cur_stage}/CONTEXT.md"
        echo "---"
    fi
}

# quintet_pipeline_list
quintet_pipeline_list() {
    local pdir; pdir="$(_quintet_pipelines_dir)"
    if [[ ! -d "$pdir" ]]; then
        echo "No active pipelines found."
        return 0
    fi

    local pipes; pipes="$(find "$pdir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)"
    if [[ -z "$pipes" ]]; then
        echo "No active pipelines found."
        return 0
    fi

    echo "Active ICM Pipelines:"
    local p pname tmpl goal
    for p in $pipes; do
        pname="$(basename "$p")"
        tmpl="custom"
        goal=""
        if [[ -f "${p}/pipeline.json" ]] && have_jq; then
            tmpl="$(jq -r '.template // "custom"' "${p}/pipeline.json" 2>/dev/null)"
            goal="$(jq -r '.goal // ""' "${p}/pipeline.json" 2>/dev/null)"
        fi
        printf '  • %-20s (template: %-12s) %s\n' "$pname" "$tmpl" "$goal"
    done
}
