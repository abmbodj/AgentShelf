import Foundation

/// Injects a keystroke into the real terminal window running a session, to answer an
/// AskUserQuestion menu the hook layer can't answer directly — hooks can allow/deny/modify a
/// tool's input, but can't supply a tool's *result*, so an in-terminal question can only be
/// answered by typing into it. Binary permissions never touch this file: they're answered
/// through the existing hook-decision socket round-trip (Approval.swift).
///
/// Verified against Claude Code 2.1.216: the AskUserQuestion menu accepts a bare digit
/// keypress (no Enter) to select and confirm an option in one step.
public enum TerminalInjector {
    /// `terminal` is TERM_PROGRAM captured from the hook's environment. Returns false if the
    /// terminal isn't scriptable or no window's cwd matches — callers must fall back to
    /// "Open in Claude" rather than risk typing into the wrong window.
    public static func inject(keys: String, cwd: String, terminal: String?) -> Bool {
        // Canonicalize via realpath (NOT URL.resolvingSymlinksInPath, which deliberately
        // leaves /tmp, /var, /etc unresolved on macOS): lsof and iTerm both report cwd through
        // the kernel's canonical form (/tmp -> /private/tmp), so an unresolved cwd never matches.
        let cwd = canonicalPath(cwd)
        switch terminal {
        case "iTerm.app": return injectITerm(keys: keys, cwd: cwd)
        case "Apple_Terminal": return injectAppleTerminal(keys: keys, cwd: cwd)
        default: return false   // Ghostty and anything else: not AppleScript-able
        }
    }

    // MARK: - iTerm2
    // ponytail: written against iTerm2's documented AppleScript dictionary (session variable
    // "session.path", `write text`) but unverified end-to-end — no iTerm2 on the dev machine.
    // Verify against a real iTerm2 install before shipping; Apple Terminal below IS verified.
    private static func injectITerm(keys: String, cwd: String) -> Bool {
        let script = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        tell s
                            set p to (variable named "session.path")
                        end tell
                        if p is equal to "\(asScript(cwd))" then
                            tell w to select
                            tell t to select
                            tell s
                                select
                                write text "\(asScript(keys))"
                            end tell
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
            return "notfound"
        end tell
        """
        return runOSAScript(script) == "ok"
    }

    // MARK: - Apple Terminal
    // Terminal.app's AppleScript dictionary has no per-tab cwd, so tabs are matched by tty:
    // list each tab's tty, find the tty's live processes via `ps`, and check each process's
    // cwd via `lsof`. First match wins — two sessions sharing a cwd (rare) can't be
    // disambiguated this way and may target the wrong tab.
    private static func injectAppleTerminal(keys: String, cwd: String) -> Bool {
        guard let tab = findAppleTerminalTab(cwd: cwd) else { return false }
        let focusScript = """
        tell application "Terminal"
            set frontmost of window id \(tab.windowId) to true
            set selected of tab \(tab.tabIndex) of window id \(tab.windowId) to true
            activate
        end tell
        """
        guard runOSAScript(focusScript) != nil else { return false }
        Thread.sleep(forTimeInterval: 0.15)   // let Terminal actually raise the tab before typing
        let keystrokeScript = """
        tell application "System Events" to tell process "Terminal"
            keystroke "\(asScript(keys))"
        end tell
        """
        return runOSAScript(keystrokeScript) != nil
    }

    private struct AppleTerminalTab { let windowId: Int; let tabIndex: Int; let tty: String }

    private static func listAppleTerminalTabs() -> [AppleTerminalTab] {
        let script = """
        tell application "Terminal"
            set out to {}
            repeat with w in windows
                set wid to id of w
                set idx to 1
                repeat with t in tabs of w
                    set end of out to ((wid as string) & "|" & (idx as string) & "|" & (tty of t))
                    set idx to idx + 1
                end repeat
            end repeat
            set AppleScript's text item delimiters to linefeed
            return out as text
        end tell
        """
        guard let raw = runOSAScript(script) else { return [] }
        return raw.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 2).map(String.init)
            guard parts.count == 3, let wid = Int(parts[0]), let idx = Int(parts[1]) else { return nil }
            return AppleTerminalTab(windowId: wid, tabIndex: idx, tty: parts[2])
        }
    }

    private static func findAppleTerminalTab(cwd: String) -> AppleTerminalTab? {
        for tab in listAppleTerminalTabs() {
            let device = tab.tty.replacingOccurrences(of: "/dev/", with: "")
            guard let pidList = runProcess("/bin/ps", ["-t", device, "-o", "pid="]) else { continue }
            for line in pidList.split(separator: "\n") {
                guard let pid = Int(line.trimmingCharacters(in: .whitespaces)) else { continue }
                guard let lsof = runProcess("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]) else { continue }
                let procCwd = lsof.split(separator: "\n").first { $0.hasPrefix("n") }.map { $0.dropFirst() }
                if let procCwd, String(procCwd) == cwd { return tab }
            }
        }
        return nil
    }

    // MARK: - Process helpers

    private static func runOSAScript(_ source: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-"]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        inPipe.fileHandleForWriting.write(Data(source.utf8))
        try? inPipe.fileHandleForWriting.close()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func runProcess(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Escape a value embedded in an AppleScript string literal (guards against cwd/keys
    /// containing a quote or backslash breaking out of the literal).
    private static func asScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// realpath(3), not URL.resolvingSymlinksInPath (which leaves /tmp, /var, /etc
    /// unresolved on macOS) — this is the same canonicalization lsof's cwd output uses.
    private static func canonicalPath(_ path: String) -> String {
        var buf = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buf) != nil else { return path }
        return String(cString: buf)
    }
}
