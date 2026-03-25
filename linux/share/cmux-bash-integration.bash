#!/usr/bin/env bash
# cmux bash shell integration
# Source this file from your .bashrc:
#   [ -n "$CMUX_WORKSPACE_ID" ] && source /path/to/cmux-bash-integration.bash
#
# Reports git branch and dirty status to cmux sidebar via V2 JSON-RPC.

# Only activate inside a cmux terminal
[[ -z "$CMUX_WORKSPACE_ID" ]] && return
[[ -z "$CMUX_SOCKET_PATH" ]] && CMUX_SOCKET_PATH="/tmp/cmux.sock"

_cmux_last_branch=""
_cmux_last_dirty=""

# Send a V2 JSON-RPC message to cmux socket.
_cmux_send() {
    local method="$1" params="$2"
    local id=$((RANDOM % 10000))
    printf '{"id":%d,"method":"%s","params":%s}\n' "$id" "$method" "$params" \
        | socat - UNIX-CONNECT:"$CMUX_SOCKET_PATH" 2>/dev/null &
}

# Called before each prompt — reports git info to cmux.
_cmux_precmd() {
    local ws_id="$CMUX_WORKSPACE_ID"
    [[ -z "$ws_id" ]] && return

    # Report git branch + dirty status
    if git rev-parse --is-inside-work-tree &>/dev/null; then
        local branch
        branch=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)
        local dirty="false"
        [[ -n "$(git status --porcelain -uno 2>/dev/null | head -1)" ]] && dirty="true"

        # Only send if changed
        if [[ "$branch" != "$_cmux_last_branch" || "$dirty" != "$_cmux_last_dirty" ]]; then
            _cmux_last_branch="$branch"
            _cmux_last_dirty="$dirty"
            _cmux_send "workspace.report_git" "{\"id\":$ws_id,\"branch\":\"$branch\",\"dirty\":$dirty}"
        fi
    elif [[ -n "$_cmux_last_branch" ]]; then
        # Left a git repo — clear branch
        _cmux_last_branch=""
        _cmux_last_dirty=""
        _cmux_send "workspace.report_git" "{\"id\":$ws_id,\"branch\":\"\",\"dirty\":false}"
    fi
}

# Install into PROMPT_COMMAND
if [[ -z "$PROMPT_COMMAND" ]]; then
    PROMPT_COMMAND="_cmux_precmd"
elif [[ "$PROMPT_COMMAND" != *"_cmux_precmd"* ]]; then
    PROMPT_COMMAND="_cmux_precmd;$PROMPT_COMMAND"
fi
