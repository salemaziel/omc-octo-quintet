#!/usr/bin/env bash
# quintet/lib/roles.sh — subagent worker role registry and prompt loader.
# Provides specialized role prompts for spawned worker agents or fleet members.
# ─────────────────────────────────────────────────────────────────────────────

# Supported standard roles
QUINTET_ROLES=(
    "implementer"
    "code-reviewer"
    "security-auditor"
    "test-engineer"
    "debugger"
    "devops-troubleshooter"
)

# Normalize role names and map common aliases
quintet_normalize_role() {
    local r
    r=$(printf '%s' "${1:-stock}" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
    case "$r" in
        reviewer)                  echo "code-reviewer" ;;
        test|tester)               echo "test-engineer" ;;
        sec|security)              echo "security-auditor" ;;
        debug)                     echo "debugger" ;;
        devops)                    echo "devops-troubleshooter" ;;
        impl)                      echo "implementer" ;;
        "")                        echo "stock" ;;
        *)                         echo "$r" ;;
    esac
}

# quintet_role_exists <role>
# Returns 0 if role is "stock" or has a corresponding role definition.
quintet_role_exists() {
    local r
    r=$(quintet_normalize_role "$1")
    [[ "$r" == "stock" ]] && return 0
    local file="${QUINTET_ROOT:-..}/roles/${r}.md"
    [[ -f "$file" ]] && return 0
    return 1
}

# quintet_role_prompt <role>
# Prints role instructions markdown if defined. Returns empty for "stock".
quintet_role_prompt() {
    local r
    r=$(quintet_normalize_role "$1")
    [[ "$r" == "stock" ]] && return 0
    local file="${QUINTET_ROOT:-..}/roles/${r}.md"
    if [[ -f "$file" ]]; then
        cat "$file"
    else
        log WARN "unknown role '$1'; falling back to stock baseline"
        return 0
    fi
}

# quintet_role_list
# Lists all built-in roles plus "stock".
quintet_role_list() {
    echo "stock"
    local r
    for r in "${QUINTET_ROLES[@]}"; do
        echo "$r"
    done
}
