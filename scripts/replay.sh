#!/bin/bash
# Drive the shelf without a live agent: replay canned hook messages over the socket.
# The wire is one JSON line per connection, so plain `nc -U` is the whole tool.
# Usage: scripts/replay.sh [demo|approval|end]   (default: demo)
set -euo pipefail

SOCK="$HOME/Library/Application Support/AgentShelf/agentshelf.sock"
CWD_JSON="${PWD//\"/}"

send() { printf '%s\n' "$1" | nc -U "$SOCK"; }

case "${1:-demo}" in
demo)
    send '{"event":"SessionStart","source":"claudeCode","sessionId":"replay-1","cwd":"'"$CWD_JSON"'","permissionKind":"none"}'
    sleep 1
    send '{"event":"PreToolUse","source":"claudeCode","sessionId":"replay-1","cwd":"'"$CWD_JSON"'","toolName":"Bash","toolSummary":"swift test","permissionKind":"none"}'
    sleep 1
    send '{"event":"SubagentStart","source":"claudeCode","sessionId":"replay-sub","parentId":"replay-1","agentType":"explore","cwd":"'"$CWD_JSON"'","permissionKind":"none"}'
    echo "demo sessions on the shelf; run '$0 approval' or '$0 end' next"
    ;;
approval)
    echo "waiting for your Allow/Deny/Always in the notch (prints the decision)…"
    send '{"event":"PermissionRequest","source":"claudeCode","sessionId":"replay-1","cwd":"'"$CWD_JSON"'","toolName":"Bash","toolSummary":"rm -rf build","permissionKind":"binary"}'
    echo
    ;;
end)
    send '{"event":"SessionEnd","source":"claudeCode","sessionId":"replay-sub","permissionKind":"none","cwd":"'"$CWD_JSON"'"}'
    send '{"event":"SessionEnd","source":"claudeCode","sessionId":"replay-1","permissionKind":"none","cwd":"'"$CWD_JSON"'"}'
    ;;
*)
    echo "usage: $0 [demo|approval|end]" >&2; exit 2
    ;;
esac
