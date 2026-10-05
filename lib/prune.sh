#!/usr/bin/env bash
# quintet/lib/prune.sh — garbage-collect defunct team state dirs and aged debates.
#
# Design:
#   1. Scans ${QUINTET_STATE_DIR}/teams/ and ${QUINTET_HOME}/teams/ for directories
#      whose tmux session has exited. Active teams are NEVER removed.
#   2. Scans ${QUINTET_HOME}/debates/ for debate archives older than N days.
#   3. Supports --days N (default: 7), --dry-run, and --force.
# ─────────────────────────────────────────────────────────────────────────────

_quintet_mtime_epoch() {
    local target="$1"
    local ep
    ep="$(stat -c %Y "$target" 2>/dev/null)" && { echo "$ep"; return 0; }
    ep="$(stat -f %m "$target" 2>/dev/null)" && { echo "$ep"; return 0; }
    python3 -c "import os; print(int(os.path.getmtime('$target')))" 2>/dev/null || echo 0
}

quintet_prune() {
    local days=7 dry_run=false force=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --days)     days="$2"; shift 2 ;;
            --dry-run)  dry_run=true; shift ;;
            --force|-f) force=true; shift ;;
            *) die "unknown prune flag: $1" ;;
        esac
    done

    local now; now="$(date +%s)"
    local cutoff_sec=$(( days * 86400 ))
    local pruned_teams=0 pruned_debates=0

    echo "==> Quintet prune: scanning for stale state older than ${days} day(s) (dry-run: ${dry_run})"

    # 1. Prune dead team directories
    local team_bases=()
    [[ -d "${QUINTET_STATE_DIR}/teams" ]] && team_bases+=("${QUINTET_STATE_DIR}/teams")
    if [[ -n "${QUINTET_HOME:-}" && -d "${QUINTET_HOME}/teams" && "${QUINTET_HOME}/teams" != "${QUINTET_STATE_DIR}/teams" ]]; then
        team_bases+=("${QUINTET_HOME}/teams")
    fi

    local tbase tdir tname mtime age
    for tbase in "${team_bases[@]}"; do
        for tdir in "${tbase}"/*; do
            [[ -d "$tdir" ]] || continue
            tname="$(basename "$tdir")"
            if quintet_session_exists "$tname"; then
                # Session is currently alive, protect it
                continue
            fi

            mtime="$(_quintet_mtime_epoch "$tdir")"
            age=$(( now - mtime ))
            if [[ "$days" -eq 0 || $age -ge $cutoff_sec ]]; then
                echo "  • Dead team state: $tname ($(basename "$tdir"), age: $((age / 86400))d)"
                pruned_teams=$((pruned_teams + 1))
                if [[ "$dry_run" != "true" ]]; then
                    rm -rf "$tdir"
                fi
            fi
        done
    done

    # 2. Prune aged debate archives
    local debate_base="${QUINTET_HOME:-$HOME/.quintet}/debates"
    local ddir dname
    if [[ -d "$debate_base" ]]; then
        for ddir in "${debate_base}"/*; do
            [[ -d "$ddir" ]] || continue
            dname="$(basename "$ddir")"
            mtime="$(_quintet_mtime_epoch "$ddir")"
            age=$(( now - mtime ))
            if [[ "$days" -eq 0 || $age -ge $cutoff_sec ]]; then
                echo "  • Stale debate archive: $dname (age: $((age / 86400))d)"
                pruned_debates=$((pruned_debates + 1))
                if [[ "$dry_run" != "true" ]]; then
                    rm -rf "$ddir"
                fi
            fi
        done
    fi

    echo "==> Prune complete: ${pruned_teams} dead team(s), ${pruned_debates} debate archive(s) removed."
}
