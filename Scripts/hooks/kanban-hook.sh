#!/usr/bin/env bash
# Kanban hook handler for Claude Code.
# Receives JSON on stdin from Claude hooks, appends a timestamped
# event line to ~/.kanban/hook-events.jsonl.
#
# Install by adding to ~/.claude/settings.json:
#   "hooks": {
#     "Stop":              [{ "type": "command", "command": "~/.kanban/hooks/kanban-hook.sh" }],
#     "Notification":      [{ "type": "command", "command": "~/.kanban/hooks/kanban-hook.sh" }],
#     "SessionStart":      [{ "type": "command", "command": "~/.kanban/hooks/kanban-hook.sh" }],
#     "SessionEnd":        [{ "type": "command", "command": "~/.kanban/hooks/kanban-hook.sh" }],
#     "UserPromptSubmit":  [{ "type": "command", "command": "~/.kanban/hooks/kanban-hook.sh" }]
#   }

set -euo pipefail

EVENTS_DIR="${HOME}/.kanban"
EVENTS_FILE="${EVENTS_DIR}/hook-events.jsonl"

# Ensure directory exists
mkdir -p "$EVENTS_DIR"

# Read the JSON payload from stdin
input=$(cat)

# Extract fields using lightweight parsing (no jq dependency)
session_id=$(echo "$input" | grep -o '"session_id":"[^"]*"' | head -1 | cut -d'"' -f4)
hook_event=$(echo "$input" | grep -o '"hook_event_name":"[^"]*"' | head -1 | cut -d'"' -f4)
transcript=$(echo "$input" | grep -o '"transcript_path":"[^"]*"' | head -1 | cut -d'"' -f4)

# Fallback: try sessionId (different hook formats)
if [ -z "$session_id" ]; then
    session_id=$(echo "$input" | grep -o '"sessionId":"[^"]*"' | head -1 | cut -d'"' -f4)
fi

# Skip if we couldn't extract a session ID
[ -z "$session_id" ] && exit 0

# Get current timestamp
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Append event line (atomic via temp file + mv for safety, but append is fine for jsonl)
printf '{"sessionId":"%s","event":"%s","timestamp":"%s","transcriptPath":"%s"}\n' \
    "$session_id" "$hook_event" "$timestamp" "$transcript" >> "$EVENTS_FILE"
