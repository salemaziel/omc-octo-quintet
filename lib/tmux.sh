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

# Every tmux call goes through qtmux. When QUINTET_TMUX_SOCKET is set, commands
# target that private server (-L) instead of the user's default one (tests use this).
qtmux() { tmux ${QUINTET_TMUX_SOCKET:+-L "$QUINTET_TMUX_SOCKET"} "$@"; }

quintet_tmux_session() { echo "quintet-$1"; }   # team name -> session name

# quintet_tmux_fmt_escape <dir> — print <dir> escaped for tmux's -c, which
# format-expands its argument: a dir named "m#(cmd)n" would run cmd. "##" is a
# literal "#". tmux copies a "#…#[" run as-is (style syntax), so "##" can't
# escape it: a dir containing "#[" is refused (returns 1, prints nothing).
quintet_tmux_fmt_escape() {
    [[ "$1" == *'#['* ]] && return 1
    printf '%s' "${1//#/##}"
}

# Pane start prefix for workers: /bin/sh copies the TERM, TMUX and TMUX_PANE that
# tmux set for this pane into an otherwise empty environment (env -i), then runs
# the rest of the argv. Workers get tmux's terminal, never the caller's (R-M1).
# sh, not bash: a non-interactive sh reads no BASH_ENV/startup file, and `exec env`
# can't hit an exported function, so nothing from the server env runs first.
# shellcheck disable=SC2016  # expands in the pane's sh
QUINTET_PANE_ENV_I=(/bin/sh -c 'exec env -i ${TERM:+"TERM=$TERM"} ${TMUX:+"TMUX=$TMUX"} ${TMUX_PANE:+"TMUX_PANE=$TMUX_PANE"} "$@"' quintet-pane)

# Targets are exact: "=sess" for sessions, "=sess:=window" for windows/panes.
# Without "=", tmux falls back to prefix/glob matching, so "foo" would hit
# "quintet-foobar" (A2).
quintet_session_exists() {
    qtmux has-session -t "=$(quintet_tmux_session "$1")" 2>/dev/null
}

# quintet_tmux_liveness <target> — alive | dead | gone | unknown for a tmux
# target (=session or =session:=window). gone = tmux says the target, its
# session or the server doesn't exist; any other tmux error is unknown, and
# callers never treat unknown as dead (nothing is killed or marked crashed on it).
quintet_tmux_liveness() {
    local out rc
    if [[ "$1" != *:* ]]; then
        # A session: has-session matches "=name" exactly (list-panes -t would
        # take it as a window target and can match another session).
        out="$(qtmux has-session -t "$1" 2>&1)" && { echo alive; return 0; }
        rc=1
    else
        out="$(qtmux list-panes -t "$1" -F '#{pane_dead}' 2>&1)"; rc=$?
    fi
    if (( rc == 0 )); then
        case "${out%%$'\n'*}" in 0) echo alive ;; 1) echo dead ;; *) echo unknown ;; esac
    elif grep -Eqi "can't find (session|window|pane)|no server running|error connecting to .*\((No such file or directory|Connection refused)\)" <<< "$out"; then
        echo gone
    else
        echo unknown
    fi
}

# Create the detached session for a team (idempotent). $2 = working dir.
quintet_session_create() {
    local team="$1" cwd="${2:-$PWD}" sess cwd_esc; sess=$(quintet_tmux_session "$team")
    if quintet_session_exists "$team"; then
        return 0
    fi
    cwd_esc="$(quintet_tmux_fmt_escape "$cwd")" || die "tmux: cannot use a directory containing '#[': $cwd"
    qtmux new-session -d -s "$sess" -c "$cwd_esc" -n "leader" \
        || die "tmux: failed to create session $sess"
    # Leader window is a passive log surface; keep it alive with a shell.
    qtmux send-keys -t "=${sess}:=leader" \
        "printf 'quintet team %s — leader log. Workers run in their own windows.\\n' '$team'" Enter
}

# Spawn one worker window. Args: team worker-name cwd "launch-command" env-file
# The window runs (argv form, no shell parsing by tmux) `env -i bash` that
# sources the worker's 0600 env file, deletes it, then execs the launch command.
# The worker's environment is only what the env file holds plus the pane's own
# TERM/TMUX/TMUX_PANE (QUINTET_PANE_ENV_I): nothing leaks in
# from the tmux server's global environment (S-M1). Secrets never appear in
# tmux/bash argv (A4, A13). remain-on-exit keeps a crashed
# worker's output inspectable. It's a window option, so the window starts on a
# placeholder, gets remain-on-exit, and only then respawn-pane -k swaps in the
# worker: a CLI that exits at once can't close the window before the option is set.
quintet_window_spawn() {
    local team="$1" worker="$2" cwd="$3" launch="$4" envf="$5" sess cwd_esc; sess=$(quintet_tmux_session "$team")
    cwd_esc="$(quintet_tmux_fmt_escape "$cwd")" \
        || { log ERROR "tmux: cannot use a directory containing '#[': $cwd"; return 1; }
    qtmux new-window -t "=$sess" -n "$worker" -c "$cwd_esc" sleep 86400 \
        || { log ERROR "tmux: failed to create window $worker"; return 1; }
    qtmux set-option -w -t "=${sess}:=${worker}" remain-on-exit on >/dev/null 2>&1 || true
    # shellcheck disable=SC2016  # $1/$2 expand in the worker's bash, not here
    qtmux respawn-pane -k -t "=${sess}:=${worker}" -c "$cwd_esc" \
        "${QUINTET_PANE_ENV_I[@]}" "${BASH:-bash}" --noprofile --norc -c '. "$1" || { echo "quintet: cannot read worker env file" >&2; exit 1; }; rm -f -- "$1"; exec bash -c "$2"' \
        quintet-worker "$envf" "$launch" \
        || { log ERROR "tmux: failed to start worker $worker"; qtmux kill-window -t "=${sess}:=${worker}" 2>/dev/null; return 1; }
}

# Type text literally into a worker window (no Enter).
quintet_window_type() {
    local team="$1" worker="$2" text="$3" sess; sess=$(quintet_tmux_session "$team")
    qtmux send-keys -t "=${sess}:=${worker}" -l "$text"
}

# quintet_window_state <team> <worker> — print "<pane_dead> <pane_in_mode>"
# ("0 0" = live and not in copy-mode); 1 if there is no such window.
quintet_window_state() {
    local team="$1" worker="$2" sess; sess=$(quintet_tmux_session "$team")
    qtmux display-message -p -t "=${sess}:=${worker}" '#{pane_dead} #{pane_in_mode}' 2>/dev/null
}

# quintet_window_input_line <team> <worker> — the input box, joined: claude and
# codex keep the cursor in it. From the cursor's row, rows are taken upward
# through the first one that starts with a prompt marker (❯ › >), stopping
# early at a blank row or a ──── rule (the cursor's own row may be blank: an
# Enter can land as a newline), at most 8 rows. So wrapped input is included
# and the transcript above, which echoes sent text, is not.
quintet_window_input_line() {
    local team="$1" worker="$2" sess y i r out="" n; sess=$(quintet_tmux_session "$team")
    local -a rows
    y="$(qtmux display-message -p -t "=${sess}:=${worker}" '#{cursor_y}' 2>/dev/null)" || return 1
    [[ "$y" =~ ^[0-9]+$ ]] || return 1
    mapfile -t rows < <(qtmux capture-pane -p -t "=${sess}:=${worker}" -S "$(( y > 7 ? y - 7 : 0 ))" -E "$y" 2>/dev/null)
    n=${#rows[@]}
    for (( i = n - 1; i >= 0; i-- )); do
        r="${rows[i]}"
        if (( i < n - 1 )); then
            [[ "$r" =~ ^[[:space:]]*$ || "$r" =~ ^[[:space:]]*(─)+[[:space:]]*$ ]] && break
        fi
        out="${r}${out}"
        [[ "$r" =~ ^[[:space:]]*(❯|›|>) ]] && break
    done
    printf '%s' "$out"
}

# Press one named key (e.g. Down, Enter) in a worker window.
quintet_window_key() {
    local team="$1" worker="$2" key="$3" sess; sess=$(quintet_tmux_session "$team")
    qtmux send-keys -t "=${sess}:=${worker}" "$key"
}

# Capture the last N lines of a worker window's visible+scrollback buffer.
quintet_window_capture() {
    local team="$1" worker="$2" lines="${3:-40}" sess; sess=$(quintet_tmux_session "$team")
    qtmux capture-pane -p -t "=${sess}:=${worker}" -S "-${lines}" 2>/dev/null
}

# List worker windows (excludes the leader log window).
quintet_window_list() {
    local team="$1" sess; sess=$(quintet_tmux_session "$team")
    qtmux list-windows -t "=$sess" -F '#{window_name}' 2>/dev/null | grep -v '^leader$' || true
}

# The current foreground command running in a worker window's active pane.
quintet_window_command() {
    local team="$1" worker="$2" sess; sess=$(quintet_tmux_session "$team")
    qtmux list-panes -t "=${sess}:=${worker}" -F '#{pane_current_command}' 2>/dev/null | head -1
}

# If a worker window's pane is dead (remain-on-exit), print its exit status
# ("?" when tmux has none, e.g. killed by a signal) and return 0; else return 1.
quintet_window_dead_status() {
    local team="$1" worker="$2" sess out; sess=$(quintet_tmux_session "$team")
    out="$(qtmux list-panes -t "=${sess}:=${worker}" -F '#{pane_dead} #{pane_dead_status}' 2>/dev/null | head -1)"
    [[ "$out" == 1* ]] || return 1
    out="${out#1}"; out="${out# }"
    echo "${out:-?}"
}

quintet_session_kill() {
    local team="$1" sess; sess=$(quintet_tmux_session "$team")
    qtmux kill-session -t "=$sess" 2>/dev/null || true
}
