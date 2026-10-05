#!/usr/bin/env bash
# quintet/lib/prune.sh — garbage-collect defunct team state dirs, aged debates and
# orphaned fleet sessions.
#
# Design:
#   1. Takes one tmux session inventory up front. tmux missing -> die. No server
#      ("no server running", or no socket file) -> zero sessions. Any other
#      list-sessions error (e.g. permission denied on the socket) -> die: prune
#      fails closed instead of treating "can't tell" as "dead".
#   2. Scans ${QUINTET_STATE_DIR}/teams/ for dirs whose session quintet-<name> is
#      not in the inventory (exact match). Each team is checked and deleted under
#      quintet_lock, and liveness is re-read under the lock. Live teams are NEVER
#      removed. A team whose team.json "tmux_socket" names another tmux server
#      is checked there with has-session; unknown liveness skips it (S-L3). Dirs whose name fails quintet_validate_team_name are skipped with
#      a WARN and a manual cleanup command. ${QUINTET_HOME}/teams is skipped with
#      a WARN (nothing writes there; no lock covers it).
#   3. Scans ${QUINTET_HOME}/debates/ for archives older than N days.
#   4. Kills orphaned quintet-fleet-<epoch>-<pid>-* sessions older than 60
#      minutes whose owner pid is dead.
#   State dirs are never followed through symlinks: a symlinked state dir,
#   teams/, locks/ or debates/ makes prune die; a symlinked entry is skipped; rm
#   only removes real, user-owned dirs directly under the resolved base.
#   Age = inactivity: newest mtime of the dir and its regular files. Unknown
#   timestamps are skipped with a WARN, never treated as old.
#   Flags: --days N (default 7), --dry-run (report candidates only).
#   --force is a deprecated no-op.
# ─────────────────────────────────────────────────────────────────────────────

# _quintet_mtime_epoch <path> — mtime in epoch seconds; nonzero on failure.
_quintet_mtime_epoch() {
    local target="$1" ep
    ep="$(stat -c %Y -- "$target" 2>/dev/null)" && [[ "$ep" =~ ^[0-9]+$ ]] && { echo "$ep"; return 0; }
    ep="$(stat -f %m -- "$target" 2>/dev/null)" && [[ "$ep" =~ ^[0-9]+$ ]] && { echo "$ep"; return 0; }
    ep="$(python3 -c 'import os,sys; print(int(os.path.getmtime(sys.argv[1])))' "$target" 2>/dev/null)" \
        && [[ "$ep" =~ ^[0-9]+$ ]] && { echo "$ep"; return 0; }
    return 1
}

# _quintet_latest_activity_epoch <dir> — newest mtime of <dir> and every regular
# file under it; nonzero if the dir, any file, or the traversal can't be read.
_quintet_latest_activity_epoch() {
    local dir="$1" newest t f
    newest="$(_quintet_mtime_epoch "$dir")" || return 1
    while IFS= read -r -d '' f; do
        [[ "$f" == "FIND_FAILED" ]] && return 1
        t="$(_quintet_mtime_epoch "$f")" || return 1
        (( t > newest )) && newest="$t"
    done < <(command find "$dir" -type f -print0 2>/dev/null || printf 'FIND_FAILED\0')
    echo "$newest"
}

# _quintet_session_inventory — print live tmux session names (one per line).
# Exit 0 with no output when no server is running; nonzero on any other error.
_quintet_session_inventory() {
    local out
    if out="$(qtmux list-sessions -F '#{session_name}' 2>&1)"; then
        [[ -n "$out" ]] && printf '%s\n' "$out"
        return 0
    fi
    [[ "$out" == *"no server running on "* || "$out" == *"error connecting to "*"(No such file or directory)"* ]] && return 0
    printf '%s\n' "$out" >&2
    return 1
}

# _quintet_foreign_session_state <team-dir> <team> — liveness of a team started on
# another tmux server (team.json "tmux_socket", S-L3). Prints "local" when there
# is no such field (or no jq) or it names our own socket; else "live", "dead",
# "unknown", or "invalid" (name fails the charset). Dead only on tmux's no-server,
# no-socket or no-session errors; any other failure is unknown.
_quintet_foreign_session_state() {
    local sock out
    have_jq && [[ -f "$1/team.json" ]] || { echo local; return 0; }
    sock="$(jq -r '.tmux_socket // empty' "$1/team.json" 2>/dev/null)" || { echo local; return 0; }
    [[ -z "$sock" || "$sock" == "${QUINTET_TMUX_SOCKET:-default}" ]] && { echo local; return 0; }
    [[ "$sock" =~ ^[A-Za-z0-9._-]+$ ]] || { echo invalid; return 0; }
    [[ "$sock" == "default" ]] && sock=""
    if out="$(tmux ${sock:+-L "$sock"} has-session -t "=quintet-$2" 2>&1)"; then
        echo live; return 0
    fi
    case "$out" in
        *"no server running on "*|*"error connecting to "*"(No such file or directory)"*|*"can't find session"*) echo dead ;;
        *) echo unknown ;;
    esac
}

quintet_prune() {
    local days=7 dry_run=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --days)
                need_arg "$1" $#
                [[ "$2" =~ ^[0-9]{1,6}$ ]] || die "--days requires a nonnegative decimal integer (max 6 digits), got '$2'"
                days=$((10#$2)); shift 2 ;;
            --dry-run)  dry_run=true; shift ;;
            --force|-f) log WARN "prune: $1 is deprecated and has no effect"; shift ;;
            *) die "unknown prune flag: $1" ;;
        esac
    done

    quintet_tmux_available || die "prune: tmux unavailable; cannot verify team liveness (nothing deleted)"
    # Never follow a symlinked state dir, teams/, locks/ or debates/ (S-H1).
    quintet_state_guard
    local debate_base="${QUINTET_HOME:-$HOME/.quintet}/debates"
    quintet_refuse_symlink "$debate_base" "debate dir"
    local inventory
    inventory="$(_quintet_session_inventory)" || die "prune: cannot read tmux session inventory (nothing deleted)"

    local now; now="$(date +%s)"
    local cutoff_sec=$(( days * 86400 ))
    local teams_n=0 debates_n=0 fleets_n=0 failures=0

    echo "==> Quintet prune: scanning for stale state older than ${days} day(s) (dry-run: ${dry_run})"

    # 1. Dead team directories (QUINTET_STATE_DIR only; it's the one team_start locks).
    if [[ -n "${QUINTET_HOME:-}" && -d "${QUINTET_HOME}/teams" && "${QUINTET_HOME}/teams" != "${QUINTET_STATE_DIR}/teams" ]]; then
        log WARN "prune: skipping ${QUINTET_HOME}/teams (not lock-protected); clean it manually if needed"
    fi
    local tdir tname mtime age lrc
    if [[ -d "${QUINTET_STATE_DIR}/teams" ]]; then
        for tdir in "${QUINTET_STATE_DIR}/teams"/*; do
            tname="$(basename "$tdir")"
            if [[ -L "$tdir" ]]; then
                log WARN "prune: skipping '$tname' (symlink, not followed). Remove the link manually if stale: rm -- $(printf '%q' "$tdir")"
                continue
            fi
            [[ -d "$tdir" ]] || continue
            if ! ( quintet_validate_team_name "$tname" ) 2>/dev/null; then
                log WARN "prune: skipping '$tname' (not a valid team name). Remove manually if stale: rm -rf -- $(printf '%q' "$tdir")"
                continue
            fi
            grep -qxF -- "quintet-${tname}" <<< "$inventory" && continue
            lrc=0; quintet_lock "$tname" || lrc=$?
            [[ $lrc -eq 2 ]] && die "prune: quintet needs GNU mv or python3 for locks"
            if [[ $lrc -ne 0 ]]; then
                log WARN "prune: skipping '$tname' (locked by another quintet process; if none is running, remove the lock: rm -rf -- $(printf '%q' "$(quintet_lock_path "$tname")"))"
                continue
            fi
            # Re-check liveness under the lock: the team may have started since
            # the inventory was taken.
            inventory="$(_quintet_session_inventory)" || { quintet_unlock "$tname"; die "prune: cannot read tmux session inventory"; }
            if grep -qxF -- "quintet-${tname}" <<< "$inventory"; then
                quintet_unlock "$tname"; continue
            fi
            # A team started on another tmux socket is live there, not here.
            case "$(_quintet_foreign_session_state "$tdir" "$tname")" in
                live)
                    quintet_unlock "$tname"; continue ;;
                unknown)
                    log WARN "prune: skipping '$tname' (cannot tell if its session on the tmux socket in team.json is live)"
                    quintet_unlock "$tname"; continue ;;
                invalid)
                    log WARN "prune: skipping '$tname' (invalid tmux_socket in team.json). Remove manually if stale: rm -rf -- $(printf '%q' "$tdir")"
                    quintet_unlock "$tname"; continue ;;
            esac
            if ! mtime="$(_quintet_latest_activity_epoch "$tdir")"; then
                log WARN "prune: skipping '$tname' (unknown timestamp)"
                quintet_unlock "$tname"; continue
            fi
            age=$(( now - mtime ))
            if [[ "$days" -eq 0 || $age -ge $cutoff_sec ]]; then
                if [[ "$dry_run" == "true" ]]; then
                    echo "  • Candidate dead team state: $tname (idle: $((age / 86400))d)"
                    teams_n=$((teams_n + 1))
                elif quintet_safe_rm_dir "$tdir" "${QUINTET_STATE_DIR}/teams"; then
                    echo "  • Removed dead team state: $tname (idle: $((age / 86400))d)"
                    teams_n=$((teams_n + 1))
                else
                    log ERROR "prune: failed to remove $tdir"
                    failures=$((failures + 1))
                fi
            fi
            quintet_unlock "$tname"
        done
    fi

    # 2. Aged debate archives.
    local ddir dname
    if [[ -d "$debate_base" ]]; then
        for ddir in "${debate_base}"/*; do
            dname="$(basename "$ddir")"
            if [[ -L "$ddir" ]]; then
                log WARN "prune: skipping debate '$dname' (symlink, not followed)"
                continue
            fi
            [[ -d "$ddir" ]] || continue
            if ! mtime="$(_quintet_latest_activity_epoch "$ddir")"; then
                log WARN "prune: skipping debate '$dname' (unknown timestamp)"
                continue
            fi
            age=$(( now - mtime ))
            if [[ "$days" -eq 0 || $age -ge $cutoff_sec ]]; then
                if [[ "$dry_run" == "true" ]]; then
                    echo "  • Candidate debate archive: $dname (idle: $((age / 86400))d)"
                    debates_n=$((debates_n + 1))
                elif quintet_safe_rm_dir "$ddir" "$debate_base"; then
                    echo "  • Removed debate archive: $dname (idle: $((age / 86400))d)"
                    debates_n=$((debates_n + 1))
                else
                    log ERROR "prune: failed to remove $ddir"
                    failures=$((failures + 1))
                fi
            fi
        done
    fi

    # 3. Orphaned fleet sessions (Ctrl-C'd / crashed fleet runs): older than 60 min
    # AND the owner pid embedded in the name is gone, so a live long-running or
    # QUINTET_FLEET_KEEP_SESSION fleet is never killed (S-L2).
    local s ep opid
    while IFS= read -r s; do
        [[ "$s" =~ ^quintet-fleet-([0-9]+)-([0-9]+)-[0-9]+$ ]] || continue
        ep="${BASH_REMATCH[1]}"; opid="${BASH_REMATCH[2]}"
        (( now - 10#$ep > 3600 )) || continue
        kill -0 "$opid" 2>/dev/null && continue
        if [[ "$dry_run" == "true" ]]; then
            echo "  • Candidate orphaned fleet session: $s"
            fleets_n=$((fleets_n + 1))
        elif qtmux kill-session -t "=$s" 2>/dev/null; then
            echo "  • Killed orphaned fleet session: $s"
            fleets_n=$((fleets_n + 1))
        else
            log ERROR "prune: failed to kill session $s"
            failures=$((failures + 1))
        fi
    done <<< "$inventory"

    if [[ "$dry_run" == "true" ]]; then
        echo "==> Prune dry-run: ${teams_n} candidate team(s), ${debates_n} candidate debate archive(s), ${fleets_n} candidate fleet session(s); nothing removed."
    else
        echo "==> Prune complete: ${teams_n} dead team(s), ${debates_n} debate archive(s) removed, ${fleets_n} orphaned fleet session(s) killed."
    fi
    if [[ $failures -gt 0 ]]; then
        log ERROR "prune: ${failures} item(s) could not be removed"
        return 1
    fi
    return 0
}
