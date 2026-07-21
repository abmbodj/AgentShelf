# AgentShelf

A macOS menu-bar app that surfaces your Claude Code sessions — approvals, status, and
activity — in the notch, so you don't have to keep switching back to the terminal.

## Install

1. Download the latest DMG from [Releases](https://github.com/abmbodj/AgentShelf/releases/latest).
2. Open it and drag **AgentShelf.app** onto the **Applications** shortcut.
3. Launch AgentShelf from Spotlight (⌘Space → "AgentShelf") like any other app.
4. From the menu bar icon, install the Claude Code hooks so sessions actually show up.

Releases are signed and notarized by Apple, so there's no Gatekeeper warning on first launch.

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

One-time setup, once per machine:

```
xcrun notarytool store-credentials AgentShelf \
  --apple-id you@example.com --team-id TEAMID --password app-specific-password
```

Then, for each release:

```
./scripts/release.sh 0.2.0
```

This stamps the version into `Info.plist`, builds a release binary, code-signs it with your
Developer ID, notarizes and staples the result, builds the DMG, and publishes a GitHub
Release with the DMG attached (via `gh`, if installed).
