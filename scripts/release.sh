#!/bin/bash
# Build and publish an AgentShelf release DMG. Signs + notarizes automatically once a
# "Developer ID Application" cert exists in the keychain; until then, ships unsigned
# (downloaders need to right-click -> Open on first launch).
#   ./scripts/release.sh 0.2.0
#
# One-time setup for signed releases (once per machine), so notarytool can authenticate
# without a password prompt:
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
# build-app.sh already signed with the best available identity (Developer ID Application,
# else the free Apple Development cert, else ad-hoc). Only a Developer ID signature is
# eligible for notarization — everything else ships as-is, unnotarized.
SIGN_ID=$(security find-identity -v -p codesigning | grep -m1 "Developer ID Application" | sed -E 's/.*"(.+)".*/\1/' || true)
if [ -n "$SIGN_ID" ]; then
  codesign --verify --deep --strict "$APP"
else
  echo "warning: no 'Developer ID Application' identity in keychain — shipping unnotarized" >&2
fi

DMG="AgentShelf-$VERSION.dmg"
rm -f "$DMG"
STAGE="$(mktemp -d)/dmg-root"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "AgentShelf" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$(dirname "$STAGE")"

if [ -n "$SIGN_ID" ]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

if command -v gh >/dev/null 2>&1; then
  gh release create "v$VERSION" "$DMG" --title "v$VERSION" --generate-notes
  echo "Published v$VERSION"
  [ -z "$SIGN_ID" ] && echo "reminder: this build is unsigned — mention right-click -> Open in the release notes"
else
  echo "gh CLI not found — DMG ready at $DMG. Publish manually: gh release create v$VERSION $DMG"
fi
