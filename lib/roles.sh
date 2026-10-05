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

# Directory holding role prompt files; anchored to this file's location when
# QUINTET_ROOT is unset (never relative to the caller's $PWD).
_quintet_roles_dir() {
    echo "${QUINTET_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/roles"
}

# quintet_role_exists <role>
# Returns 0 if role is "stock" or a plain name ([a-z0-9-]+) with a roles/<r>.md file.
quintet_role_exists() {
    local r
    r=$(quintet_normalize_role "$1")
    [[ "$r" == "stock" ]] && return 0
    [[ "$r" =~ ^[a-z0-9-]+$ ]] || return 1
    [[ -f "$(_quintet_roles_dir)/${r}.md" ]]
}

# quintet_role_prompt <role>
# Prints role instructions markdown if defined. Returns empty for "stock".
quintet_role_prompt() {
    local r
    r=$(quintet_normalize_role "$1")
    [[ "$r" == "stock" ]] && return 0
    if quintet_role_exists "$r"; then
        cat "$(_quintet_roles_dir)/${r}.md"
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
