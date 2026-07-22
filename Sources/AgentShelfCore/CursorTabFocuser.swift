import Foundation
import AppKit
import ApplicationServices

/// Best-effort tab targeting for Claude Code sessions running inside Cursor's own integrated
/// terminal. `TerminalInjector` already does this for iTerm2/Apple Terminal via their
/// AppleScript dictionaries — Cursor (Electron/Chromium) has none, so this uses two different
/// tricks instead:
///   1. Tag the exact tty the hook reported (see `ControllingTTY`) with a marker, written as a
///      terminal-title escape sequence straight into the tty device — the same mechanism any
///      shell/CLI uses to set its own tab title, just performed from outside that process.
///   2. Force Cursor's normally-lazy accessibility tree open (Chromium only builds it for a
///      detected assistive-technology client) and scan for the tab now carrying that marker.
///
/// Requires Cursor's `terminal.integrated.tabs.description` to include `${sequence}` for the
/// tag to actually surface anywhere in the tab's accessible text — see
/// `CursorSettingsInstaller`. Without that, tagging is a harmless no-op and `focus` just
/// returns false (safe to fall back to `JumpService`).
///
/// Verified only that Cursor's editor-tab strip is individually identifiable/selectable this
/// way via a live AX-tree dump (Chromium's own "Tabs" widget, reused by the terminal panel);
/// NOT yet verified end-to-end against a real multi-tab terminal panel. Gate any GUI-automation
/// test behind an `AGENTSHELF_DEBUG_*` env var, same convention as `TerminalInjectorTests`.
public enum CursorTabFocuser {
    /// Tags `tty` with `marker`, waits briefly for Cursor to relabel the tab, then finds and
    /// selects it. Returns false the moment anything can't be confirmed, so callers always have
    /// a safe path to fall back to `JumpService.focus(cwd:)`.
    public static func focus(tty: String, marker: String) -> Bool {
        guard tag(tty: tty, marker: marker) else { return false }
        Thread.sleep(forTimeInterval: 0.15)
        return selectTab(marker: marker)
    }

    // MARK: - Tagging

    /// OSC 0 (icon + window title) escape sequence, written directly to the tty device path —
    /// no AppleScript needed since the hook already told us exactly which tty to write to.
    private static func tag(tty: String, marker: String) -> Bool {
        let fd = open(tty, O_WRONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let bytes = Array("\u{1B}]0;\(marker)\u{07}".utf8)
        let written = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        return written == bytes.count
    }

    // MARK: - Accessibility

    private static func selectTab(marker: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == "Cursor" })
        else { return false }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        // Chromium/Electron only builds its full accessibility tree lazily for a detected
        // assistive-technology client. This custom attribute forces it regardless of whether
        // one is actually running — verified against a real Cursor build.
        _ = AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        guard let windows = copyAttribute(appEl, kAXWindowsAttribute) as? [AXUIElement] else { return false }
        for window in windows {
            guard let tab = findTabButton(in: window, marker: marker) else { continue }
            AXUIElementPerformAction(tab, kAXPressAction as CFString)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            app.activate()
            return true
        }
        return false
    }

    /// Iterative, node-budgeted DFS for an `AXTabButton` whose title or description contains
    /// `marker` — budgeted so a pathological tree can never hang the caller (this runs on the
    /// notch's main actor).
    private static func findTabButton(in root: AXUIElement, marker: String) -> AXUIElement? {
        var stack: [AXUIElement] = [root]
        var visited = 0
        let budget = 20_000
        while let el = stack.popLast() {
            visited += 1
            if visited > budget { return nil }
            if stringAttribute(el, kAXSubroleAttribute) == "AXTabButton" {
                let title = stringAttribute(el, kAXTitleAttribute) ?? ""
                let description = stringAttribute(el, kAXDescriptionAttribute) ?? ""
                if title.contains(marker) || description.contains(marker) { return el }
            }
            if let kids = copyAttribute(el, kAXChildrenAttribute) as? [AXUIElement] {
                stack.append(contentsOf: kids)
            }
        }
        return nil
    }

    private static func copyAttribute(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(el, name as CFString, &value)
        return err == .success ? value : nil
    }

    private static func stringAttribute(_ el: AXUIElement, _ name: String) -> String? {
        copyAttribute(el, name) as? String
    }
}
