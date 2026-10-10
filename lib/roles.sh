#!/usr/bin/env bash
# quintet/lib/roles.sh — subagent worker role registry and prompt loader.
# Provides specialized role prompts for spawned worker agents or fleet members across 9 domains:
# Engineering, Design, Business, Marketing, Sales, Philosophy, Legal, Operations, Education.
# ─────────────────────────────────────────────────────────────────────────────

# Supported standard categories
QUINTET_CATEGORIES=(
    "engineering"
    "design"
    "business"
    "marketing"
    "sales"
    "philosophy"
    "legal"
    "operations"
    "education"
)

# Supported standard roles across all domains
QUINTET_ROLES=(
    # Engineering
    "system-architect"
    "api-designer"
    "implementer"
    "refactoring-specialist"
    "code-reviewer"
    "test-engineer"
    "debugger"
    "database-engineer"
    "performance-engineer"
    "security-auditor"
    "devops-troubleshooter"
    "site-reliability-engineer"
    "technical-writer"
    "prompt-engineer"
    "release-captain"
    "codebase-auditor"
    "secret-scanner"
    "kubernetes-architect"

    # Design (inc. Web Design)
    "web-designer"
    "conversion-designer"
    "ui-designer"
    "design-system-architect"
    "ux-architect"
    "accessibility-specialist"
    "ux-researcher"
    "chief-designer"

    # Business
    "business-strategist"
    "competitive-analyst"
    "product-manager"
    "pricing-strategist"

    # Marketing
    "brand-strategist"
    "copywriter"
    "technical-content-strategist"
    "growth-engineer"
    "seo-specialist"
    "launch-strategist"

    # Sales
    "sales-engineer"
    "outbound-strategist"
    "deal-strategist"
    "customer-success-lead"

    # Philosophy
    "first-principles-analyst"
    "dialectical-challenger"
    "tech-ethicist"
    "unix-philosopher"

    # Legal
    "licensing-auditor"
    "privacy-officer"
    "policy-author"

    # Operations
    "workflow-orchestrator"
    "knowledge-architect"

    # Education
    "learning-scientist"
    "curriculum-architect"
    "instructional-designer"
    "metacognition-coach"
    "inclusive-educator"
    "ai-tutor-architect"
)

# Normalize role names and map common aliases
quintet_normalize_role() {
    local raw="$1"
    # Reject directory traversal immediately
    if [[ "$raw" == *".."* ]]; then
        echo "$raw"
        return 0
    fi

    local r
    r=$(printf '%s' "${raw:-stock}" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
    # Strip optional category prefix (e.g. 'marketing/copywriter' -> 'copywriter')
    r="${r##*/}"

    case "$r" in
        # Engineering aliases
        arch|architect)                                   echo "system-architect" ;;
        api|interface-designer)                           echo "api-designer" ;;
        impl)                                             echo "implementer" ;;
        refactor|simplifier|cleaner)                      echo "refactoring-specialist" ;;
        reviewer)                                         echo "code-reviewer" ;;
        test|tester)                                      echo "test-engineer" ;;
        debug)                                            echo "debugger" ;;
        db|database|dba)                                  echo "database-engineer" ;;
        perf|performance|optimizer)                       echo "performance-engineer" ;;
        sec|security)                                     echo "security-auditor" ;;
        devops)                                           echo "devops-troubleshooter" ;;
        sre|observability)                                echo "site-reliability-engineer" ;;
        docs|writer|tech-writer)                          echo "technical-writer" ;;
        prompt|prompter|prompt-craft)                     echo "prompt-engineer" ;;
        release|releng|ship-captain)                      echo "release-captain" ;;
        audit|codebase-audit|full-audit)                  echo "codebase-auditor" ;;
        secrets|secret-scan|cred-scan)                    echo "secret-scanner" ;;
        k8s|k8s-architect|kube)                           echo "kubernetes-architect" ;;

        # Design aliases
        webdesign|landing-designer)                       echo "web-designer" ;;
        cro|cro-designer|funnel-designer)                 echo "conversion-designer" ;;
        ui|component-designer)                            echo "ui-designer" ;;
        design-tokens|token-architect)                    echo "design-system-architect" ;;
        ux|interaction-designer)                          echo "ux-architect" ;;
        a11y|accessibility)                               echo "accessibility-specialist" ;;
        ux-research|user-researcher)                      echo "ux-researcher" ;;
        chief-design|design-lead|lead-designer)           echo "chief-designer" ;;

        # Business aliases
        biz-strat|corporate-strategist)                   echo "business-strategist" ;;
        comp-analyst|market-intelligence)                 echo "competitive-analyst" ;;
        pm|product-strategist)                            echo "product-manager" ;;
        pricing|monetization)                             echo "pricing-strategist" ;;

        # Marketing aliases
        brand|positioning)                                echo "brand-strategist" ;;
        copy|content-writer)                              echo "copywriter" ;;
        tech-marketer|devrel)                             echo "technical-content-strategist" ;;
        growth|plg-strategist)                            echo "growth-engineer" ;;
        seo|search-strategist)                            echo "seo-specialist" ;;
        launch|pr-specialist)                             echo "launch-strategist" ;;

        # Sales aliases
        se|solutions-architect)                           echo "sales-engineer" ;;
        sdr|pipeline-generator)                           echo "outbound-strategist" ;;
        closer|commercial-negotiator)                     echo "deal-strategist" ;;
        cs-lead|retention-strategist)                     echo "customer-success-lead" ;;

        # Philosophy aliases
        first-principles|epistemologist)                  echo "first-principles-analyst" ;;
        devils-advocate|socratic-inquisitor)              echo "dialectical-challenger" ;;
        ethicist|humane-tech)                             echo "tech-ethicist" ;;
        minimalist|software-purist)                       echo "unix-philosopher" ;;

        # Legal aliases
        license-auditor|oss-compliance)                   echo "licensing-auditor" ;;
        compliance-officer|privacy-auditor)               echo "privacy-officer" ;;
        legal-writer|terms-counsel)                       echo "policy-author" ;;

        # Operations aliases
        agile-coach|scrum-master)                         echo "workflow-orchestrator" ;;
        wiki-curator|ops-docs)                            echo "knowledge-architect" ;;

        # Education aliases
        cognitive-designer|memory-coach)                  echo "learning-scientist" ;;
        curriculum-designer|ubd-designer)                 echo "curriculum-architect" ;;
        pedagogical-coach|explicit-instructor)            echo "instructional-designer" ;;
        srl-mentor|agency-coach)                          echo "metacognition-coach" ;;
        udl-specialist|eal-specialist)                    echo "inclusive-educator" ;;
        socratic-tutor|cognitive-tutor)                   echo "ai-tutor-architect" ;;

        "")                                               echo "stock" ;;
        *)                                                echo "$r" ;;
    esac
}

# Directory holding role prompt files; anchored to this file's location when
# QUINTET_ROOT is unset (never relative to the caller's $PWD).
_quintet_roles_dir() {
    echo "${QUINTET_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/roles"
}

# quintet_role_file <role>
# Returns 0 and prints full path to the role .md file if it exists.
quintet_role_file() {
    local raw="$1"
    [[ "$raw" == *".."* ]] && return 1

    local r
    r=$(quintet_normalize_role "$raw")
    [[ "$r" == "stock" ]] && return 0
    [[ "$r" =~ ^[a-z0-9-]+$ ]] || return 1

    local rdir
    rdir="$(_quintet_roles_dir)"

    # 1. Direct path in roles/ (or top-level symlink)
    if [[ -f "${rdir}/${r}.md" ]]; then
        echo "${rdir}/${r}.md"
        return 0
    fi

    # 2. Category subdirectory check
    local found
    found="$(find "$rdir" -mindepth 2 -maxdepth 2 -type f -name "${r}.md" 2>/dev/null | head -n 1)"
    if [[ -n "$found" && -f "$found" ]]; then
        echo "$found"
        return 0
    fi

    return 1
}

# quintet_role_exists <role>
# Returns 0 if role is "stock" or a plain name with an existing roles/<r>.md file.
quintet_role_exists() {
    local raw="$1"
    [[ "$raw" == *".."* ]] && return 1

    local r
    r=$(quintet_normalize_role "$raw")
    [[ "$r" == "stock" ]] && return 0
    [[ "$r" =~ ^[a-z0-9-]+$ ]] || return 1

    quintet_role_file "$r" >/dev/null 2>&1
}

# quintet_role_prompt <role>
# Prints role instructions markdown if defined. Returns empty for "stock".
quintet_role_prompt() {
    local raw="$1"
    [[ "$raw" == *".."* ]] && return 1

    local r
    r=$(quintet_normalize_role "$raw")
    [[ "$r" == "stock" ]] && return 0

    local f
    if f="$(quintet_role_file "$r")"; then
        cat "$f"
    else
        log WARN "unknown role '$raw'; falling back to stock baseline"
        return 0
    fi
}

# quintet_role_category <role>
# Prints the category of a role (e.g. engineering, design, education)
quintet_role_category() {
    local r f
    r=$(quintet_normalize_role "$1")
    f="$(quintet_role_file "$r" 2>/dev/null)" || return 1
    # resolve symlink target to get real category folder
    local target
    target="$(readlink -f "$f" 2>/dev/null || echo "$f")"
    basename "$(dirname "$target")"
}

# quintet_role_skills <role>
# Extracts recommended skills from role file frontmatter as markdown bullet points.
quintet_role_skills() {
    local raw="$1"
    [[ "$raw" == *".."* ]] && return 1

    local r
    r=$(quintet_normalize_role "$raw")
    [[ "$r" == "stock" ]] && return 0

    local f
    f="$(quintet_role_file "$r" 2>/dev/null)" || return 1
    [[ -f "$f" ]] || return 1

    local in_frontmatter=0 in_skills=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "---" ]]; then
            if (( in_frontmatter == 0 )); then
                in_frontmatter=1
                continue
            else
                break
            fi
        fi

        if (( in_frontmatter == 1 )); then
            if [[ "$line" =~ ^(recommended_skills|skills): ]]; then
                in_skills=1
                continue
            fi
            if (( in_skills == 1 )); then
                if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+(.*) ]]; then
                    local s="${BASH_REMATCH[1]}"
                    s="${s#\"}"
                    s="${s#\'}"
                    s="${s%\"}"
                    s="${s%\'}"
                    echo "- \`$s\`"
                elif [[ "$line" =~ ^[A-Za-z0-9_]+: ]]; then
                    in_skills=0
                fi
            fi
        fi
    done < "$f"
}

# quintet_role_list [category|--plain]
# Lists roles. When run interactively, displays grouped categories.
# In pipes or with --plain, prints a flat newline-separated list starting with stock.
quintet_role_list() {
    local mode="${1:-}"

    # Plain list mode (for scripts, tests, pipes)
    if [[ "$mode" == "--plain" ]] || [[ -n "$mode" && "$mode" == "stock" ]] || [[ ! -t 1 && -z "$mode" ]]; then
        echo "stock"
        local r
        for r in "${QUINTET_ROLES[@]}"; do
            echo "$r"
        done
        return 0
    fi

    # Filtered by category
    if [[ -n "$mode" && "$mode" != "--all" ]]; then
        local cat="$mode"
        local cat_dir="$(_quintet_roles_dir)/${cat}"
        if [[ ! -d "$cat_dir" ]]; then
            echo "Unknown category: '$cat'. Supported categories: ${QUINTET_CATEGORIES[*]}" >&2
            return 1
        fi
        echo "=== Category: ${cat} ==="
        local f rname
        for f in "${cat_dir}"/*.md; do
            [[ -f "$f" ]] || continue
            rname="$(basename "$f" .md)"
            local summary
            summary="$(grep -E '^description:' "$f" 2>/dev/null | head -n 1 | sed -e 's/^description:[[:space:]]*//' -e 's/^["'"'"']//' -e 's/["'"'"']$//')"
            if [[ -z "$summary" ]]; then
                summary="$(grep -E '^Specialized instructions for' "$f" 2>/dev/null | sed 's/Specialized instructions for //; s/\.$//')"
            fi
            if [[ -z "$summary" ]]; then
                summary="$(head -n 3 "$f" | tail -n 1)"
            fi
            printf '  %-28s %s\n' "$rname" "${summary:-}"
        done
        return 0
    fi

    # Interactive grouped overview
    echo "quintet roles — 55 expert personas across 9 domains"
    echo
    echo "  Baseline: stock (unprompted CLI default)"
    echo
    local c f rname
    for c in "${QUINTET_CATEGORIES[@]}"; do
        local cdir="$(_quintet_roles_dir)/${c}"
        [[ -d "$cdir" ]] || continue
        echo "── [${c^^}] ──"
        for f in "${cdir}"/*.md; do
            [[ -f "$f" ]] || continue
            rname="$(basename "$f" .md)"
            local summary
            summary="$(grep -E '^description:' "$f" 2>/dev/null | head -n 1 | sed -e 's/^description:[[:space:]]*//' -e 's/^["'"'"']//' -e 's/["'"'"']$//')"
            if [[ -z "$summary" ]]; then
                summary="$(grep -E '^Specialized instructions for' "$f" 2>/dev/null | sed 's/Specialized instructions for //; s/\.$//')"
            fi
            printf '  %-28s %s\n' "$rname" "${summary:-}"
        done
        echo
    done
    echo "Usage in team / worktrees specs:  quintet team 1:claude:<role> \"...\""
    echo "Filter by category:               quintet roles <category> (e.g. quintet roles education)"
}
