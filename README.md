# AgentShelf

A macOS menu-bar app that surfaces your Claude Code sessions — approvals, status, and
activity — in the notch, so you don't have to keep switching back to the terminal.

## Install

1. Download the latest DMG from [Releases](https://github.com/abmbodj/AgentShelf/releases/latest).
2. Open it and drag **AgentShelf.app** onto the **Applications** shortcut.
3. Launch AgentShelf from Spotlight (⌘Space → "AgentShelf") like any other app.
4. From the menu bar icon, install the Claude Code hooks so sessions actually show up.

Signed, notarized releases open with no Gatekeeper warning. If a release is unsigned (no
Developer ID cert configured yet), macOS will block it on first launch — right-click
**AgentShelf.app** → **Open** → **Open** to run it anyway.

AgentShelf itself checks for new releases on launch and shows an "Update available" item in
the menu bar when one exists — no auto-install, it just links you to the release page.

## Development

Requires Swift 6.2+ / Xcode 16+, macOS 14+.

```
swift build              # compile only, run with `swift run AgentShelfApp`
./scripts/dev.sh         # kill running instance, debug build, relaunch the bundled app
```

Use `scripts/dev.sh` (not `swift run`) when working on anything that depends on the app
being a real bundle — launch-at-login, single-instance enforcement, the app icon.

```
swift test                # run the test suite
```

## Releasing (maintainers)

```
./scripts/release.sh 0.2.0
```

This stamps the version into `Info.plist`, builds a release binary, builds the DMG, and
publishes a GitHub Release with the DMG attached (via `gh`, if installed).

If a "Developer ID Application" certificate is in your keychain, it also code-signs,
notarizes, and staples the build automatically — otherwise it ships unsigned. To enable
signing, one-time per machine:

```
xcrun notarytool store-credentials AgentShelf \
  --apple-id you@example.com --team-id TEAMID --password app-specific-password
```

(plus generating the Developer ID Application cert itself via Xcode → Settings → Accounts →
Manage Certificates, which requires an active paid Apple Developer Program membership).
