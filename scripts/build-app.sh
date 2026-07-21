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

ICON_SRC="Resources/AppIcon-source.png"
ICON_ICNS="Resources/AppIcon.icns"
if [ -f "$ICON_SRC" ]; then
  ICONSET=$(mktemp -d)/AppIcon.iconset
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size * 2))" "$((size * 2))" "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$ICON_ICNS"
  rm -rf "$(dirname "$ICONSET")"
fi
if [ -f "$ICON_ICNS" ]; then
  mkdir -p "$APP/Contents/Resources"
  cp "$ICON_ICNS" "$APP/Contents/Resources/AppIcon.icns"
else
  echo "warning: no $ICON_ICNS (drop a source image at $ICON_SRC to generate one) — building without an app icon" >&2
fi

echo "Built $APP  ($CONFIG)"
echo "Run it:  open $APP"
