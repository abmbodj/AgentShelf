#!/bin/bash
# Assemble AgentShelf.app from the SPM binaries so it runs as a proper menu-bar app
# (reliable status-bar icon, survives independent of any terminal).
#   ./scripts/build-app.sh [debug|release]   (default: release)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="AgentShelf.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

# The app resolves agentshelf-hook next to its own executable, so bundle all three.
cp "$BIN/AgentShelfApp"   "$APP/Contents/MacOS/AgentShelf"
cp "$BIN/agentshelf-hook" "$APP/Contents/MacOS/agentshelf-hook"
cp "$BIN/agentshelf-setup" "$APP/Contents/MacOS/agentshelf-setup"
cp Resources/AgentShelf-Info.plist "$APP/Contents/Info.plist"

echo "Built $APP  ($CONFIG)"
echo "Run it:  open $APP"
