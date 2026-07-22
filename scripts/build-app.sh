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

MENUBAR_ICON_SRC="Resources/MenuBarIcon-source.png"
if [ -f "$MENUBAR_ICON_SRC" ]; then
  mkdir -p "$APP/Contents/Resources"
  cp "$MENUBAR_ICON_SRC" "$APP/Contents/Resources/MenuBarIcon.png"
else
  echo "warning: no $MENUBAR_ICON_SRC — menu bar will fall back to the cpu symbol" >&2
fi

# Sign with the best available identity so the bundle's identity is STABLE across rebuilds —
# an ad-hoc signature changes every build (different bytes), which makes SMAppService/BTM treat
# each build as a new app and pile up duplicate Login Items entries instead of updating one.
# Prefer a real distribution identity; fall back to the free per-Apple-ID dev cert; if neither
# exists, leave the linker's ad-hoc signature as-is (unchanged from before).
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Developer ID Application" | sed -E 's/.*"(.+)".*/\1/' || true)
[ -z "$SIGN_ID" ] && SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" | sed -E 's/.*"(.+)".*/\1/' || true)

if [ -n "$SIGN_ID" ]; then
  for bin in agentshelf-hook agentshelf-setup AgentShelf; do
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP/Contents/MacOS/$bin"
  done
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
fi

echo "Built $APP  ($CONFIG)$([ -n "$SIGN_ID" ] && echo "  signed: $SIGN_ID")"
echo "Run it:  open $APP"
