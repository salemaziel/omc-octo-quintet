#!/usr/bin/env bash
# quintet/lib/tmux.sh — tmux surface helpers for the persistent team runtime.
#
# Design: each quintet team is a dedicated *detached* tmux session named
# "quintet-<team>". Every worker is its own window (window 0 = leader log). This
# works identically whether the caller is inside tmux, inside cmux, or in a plain
# terminal — we never split the caller's current surface, so nothing breaks if
# $TMUX is unset. Attach later with: tmux attach -t quintet-<team>
# ─────────────────────────────────────────────────────────────────────────────

quintet_tmux_available() { command -v tmux >/dev/null 2>&1; }

quintet_tmux_session() { echo "quintet-$1"; }   # team name -> session name

quintet_session_exists() {
    tmux has-session -t "$(quintet_tmux_session "$1")" 2>/dev/null
}

# Create the detached session for a team (idempotent). $2 = working dir.
quintet_session_create() {
    local team="$1" cwd="${2:-$PWD}" sess; sess=$(quintet_tmux_session "$team")
    if quintet_session_exists "$team"; then
        return 0
    fi
    tmux new-session -d -s "$sess" -c "$cwd" -n "leader" \
        || die "tmux: failed to create session $sess"
    # Leader window is a passive log surface; keep it alive with a shell.
    tmux send-keys -t "${sess}:leader" \
        "printf 'quintet team %s — leader log. Workers run in their own windows.\\n' '$team'" Enter
}

# Spawn one worker window. Args: team worker-name cwd "launch-command"
quintet_window_spawn() {
    local team="$1" worker="$2" cwd="$3" launch="$4" sess; sess=$(quintet_tmux_session "$team")
    tmux new-window -t "$sess" -n "$worker" -c "$cwd" \
        || { log ERROR "tmux: failed to create window $worker"; return 1; }
    tmux send-keys -t "${sess}:${worker}" "$launch" Enter
}

# Inject text into a worker window, then press Enter as a separate keystroke
# (many TUIs need the newline delivered on its own to submit).
quintet_window_send() {
    local team="$1" worker="$2" text="$3" sess; sess=$(quintet_tmux_session "$team")
    tmux send-keys -t "${sess}:${worker}" -l "$text"
    sleep 0.4
    tmux send-keys -t "${sess}:${worker}" Enter
}

# Capture the last N lines of a worker window's visible+scrollback buffer.
quintet_window_capture() {
    local team="$1" worker="$2" lines="${3:-40}" sess; sess=$(quintet_tmux_session "$team")
    tmux capture-pane -p -t "${sess}:${worker}" -S "-${lines}" 2>/dev/null
}

# List worker windows (excludes the leader log window).
quintet_window_list() {
    local team="$1" sess; sess=$(quintet_tmux_session "$team")
    tmux list-windows -t "$sess" -F '#{window_name}' 2>/dev/null | grep -v '^leader$' || true
}

# The current foreground command running in a worker window's active pane.
quintet_window_command() {
    local team="$1" worker="$2" sess; sess=$(quintet_tmux_session "$team")
    tmux list-panes -t "${sess}:${worker}" -F '#{pane_current_command}' 2>/dev/null | head -1
}

quintet_session_kill() {
    local team="$1" sess; sess=$(quintet_tmux_session "$team")
    tmux kill-session -t "$sess" 2>/dev/null || true
}
