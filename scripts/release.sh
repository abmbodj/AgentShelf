#!/bin/bash
# Build, sign, notarize, and publish a signed AgentShelf release DMG.
#   ./scripts/release.sh 0.2.0
#
# One-time setup (once per machine), so notarytool can authenticate without a password prompt:
#   xcrun notarytool store-credentials AgentShelf --apple-id you@example.com --team-id TEAMID --password app-specific-password
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version, e.g. 0.2.0>}"
NOTARY_PROFILE="${NOTARY_PROFILE:-AgentShelf}"

PLIST="Resources/AgentShelf-Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$PLIST"

./scripts/build-app.sh release

APP="AgentShelf.app"
SIGN_ID=$(security find-identity -v -p codesigning | grep -m1 "Developer ID Application" | sed -E 's/.*"(.+)".*/\1/')
if [ -z "$SIGN_ID" ]; then
  echo "No 'Developer ID Application' identity found in keychain." >&2
  exit 1
fi

# Sign every loose executable in the bundle before signing the bundle itself —
# notarization rejects unsigned nested code.
for bin in agentshelf-hook agentshelf-setup AgentShelf; do
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP/Contents/MacOS/$bin"
done
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict "$APP"

DMG="AgentShelf-$VERSION.dmg"
rm -f "$DMG"
STAGE="$(mktemp -d)/dmg-root"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "AgentShelf" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$(dirname "$STAGE")"

xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

if command -v gh >/dev/null 2>&1; then
  gh release create "v$VERSION" "$DMG" --title "v$VERSION" --generate-notes
  echo "Published v$VERSION"
else
  echo "gh CLI not found — DMG ready at $DMG. Publish manually: gh release create v$VERSION $DMG"
fi
