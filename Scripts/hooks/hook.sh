#!/usr/bin/env bash
# ClaudeBoard hook handler for Claude Code.
# Receives JSON on stdin from hooks, appends a timestamped
# event line to ~/.claude-board/hook-events.jsonl.

set -euo pipefail

EVENTS_DIR="${HOME}/.claude-board"
EVENTS_FILE="${EVENTS_DIR}/hook-events.jsonl"

mkdir -p "$EVENTS_DIR"

input=$(cat)

session_id=$(echo "$input" | grep -o '"session_id":"[^"]*"' | head -1 | cut -d'"' -f4)
hook_event=$(echo "$input" | grep -o '"hook_event_name":"[^"]*"' | head -1 | cut -d'"' -f4)
transcript=$(echo "$input" | grep -o '"transcript_path":"[^"]*"' | head -1 | cut -d'"' -f4)

if [ -z "$session_id" ]; then
    session_id=$(echo "$input" | grep -o '"sessionId":"[^"]*"' | head -1 | cut -d'"' -f4)
fi

[ -z "$session_id" ] && exit 0

tmux_session=$(tmux display-message -p '#S' 2>/dev/null || echo "")
claude_pid=$PPID
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

printf '{"sessionId":"%s","event":"%s","timestamp":"%s","transcriptPath":"%s","tmuxSession":"%s","pid":%d}\n' \
    "$session_id" "$hook_event" "$timestamp" "$transcript" "$tmux_session" "$claude_pid" >> "$EVENTS_FILE"
