import Foundation

/// Focuses an editor window for a session's cwd. Extension seam: new editors/terminals
/// are new values, added to JumpService.preferred (Phase 2 adds terminals).
public struct EditorJump: Sendable, Equatable {
    public let appName: String
    public init(appName: String) { self.appName = appName }

    /// argv for `/usr/bin/open -a <app> <cwd>` — activates the editor and focuses/opens
    /// the window for that folder. VS Code-family editors reuse an existing window when
    /// the folder is already open, which is our cwd->window binding for the common case.
    public func openArgs(cwd: String) -> [String] { ["-a", appName, cwd] }

    @discardableResult public func focus(cwd: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = openArgs(cwd: cwd)
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
        catch { return false }
    }
}

/// Jumps to the exact terminal a session runs in, keyed by TERM_PROGRAM. Precise where the
/// terminal is scriptable (iTerm2/Apple Terminal via AppleScript, WezTerm/kitty via CLI
/// remote-control, tmux via `select-pane`); otherwise best-effort app activation. Every step
/// fails safe to false so the caller can fall back to `JumpService` (editor) as a last resort.
public enum TerminalJump {
    /// TERM_PROGRAM -> the .app to raise when we can't script the exact tab. Anything not here
    /// (Warp, Zed, Hyper, Termius, cmux, Conductor, …) gets no precise path and returns false.
    static let appForTerm: [String: String] = [
        "iTerm.app": "iTerm", "Apple_Terminal": "Terminal", "ghostty": "Ghostty",
        "WezTerm": "WezTerm", "kitty": "kitty", "Warp": "Warp", "Hyper": "Hyper",
        "Tabby": "Tabby", "rio": "Rio", "Alacritty": "Alacritty",
    ]

    @discardableResult
    public static func focus(terminal: String?, cwd: String, tty: String? = nil) -> Bool {
        guard let terminal else { return false }
        // 1. Precise tab/pane, where the terminal exposes one.
        if TerminalInjector.focusTab(cwd: cwd, terminal: terminal) { return true }
        if terminal == "WezTerm", weztermActivate(cwd: cwd) { return true }
        if terminal == "kitty", kittyFocus(cwd: cwd) { return true }
        if terminal == "tmux" { return tmuxSelect(cwd: cwd) }   // no outer app to raise from here
        // 2. Best-effort app activation for a known-but-unscriptable terminal.
        if let app = appForTerm[terminal] { return activate(app: app) }
        return false
    }

    // ponytail: WezTerm/kitty/tmux paths are written to their documented CLIs but unverified on
    // this machine (tools not installed). They fail safe to false, so a wrong assumption only
    // costs the precise jump, never correctness.
    private static func weztermActivate(cwd: String) -> Bool {
        guard let json = runProcess("wezterm", ["cli", "list", "--format", "json"]),
              let panes = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] else { return false }
        for pane in panes {
            let paneCwd = (pane["cwd"] as? String)?.replacingOccurrences(of: "file://", with: "")
            guard paneCwd?.hasSuffix(cwd) == true, let id = pane["pane_id"] as? Int else { continue }
            _ = runProcess("wezterm", ["cli", "activate-pane", "--pane-id", "\(id)"])
            activate(app: "WezTerm")
            return true
        }
        return false
    }

    private static func kittyFocus(cwd: String) -> Bool {
        guard let json = runProcess("kitty", ["@", "ls"]),
              let windows = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] else { return false }
        for osWindow in windows {
            for tab in (osWindow["tabs"] as? [[String: Any]]) ?? [] {
                for w in (tab["windows"] as? [[String: Any]]) ?? [] where (w["cwd"] as? String) == cwd {
                    guard let id = w["id"] as? Int else { continue }
                    _ = runProcess("kitty", ["@", "focus-window", "--match", "id:\(id)"])
                    activate(app: "kitty")
                    return true
                }
            }
        }
        return false
    }

    private static func tmuxSelect(cwd: String) -> Bool {
        guard let list = runProcess("tmux", ["list-panes", "-a", "-F", "#{pane_id} #{pane_current_path}"]) else { return false }
        for line in list.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[1] == cwd else { continue }
            _ = runProcess("tmux", ["switch-client", "-t", parts[0]]) ?? runProcess("tmux", ["select-window", "-t", parts[0]])
            _ = runProcess("tmux", ["select-pane", "-t", parts[0]])
            return true
        }
        return false
    }

    @discardableResult
    private static func activate(app: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", app]
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
    }

    /// Run a tool found on PATH, capturing stdout. nil on any failure (tool absent, nonzero exit).
    private static func runProcess(_ tool: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [tool] + args
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

public enum JumpService {
    /// No hook payload carries a window id, so we can't know which app hosts a session.
    /// We focus the user's preferred editor for that folder — Cursor first, VS Code next.
    public static let preferred: [EditorJump] = [
        EditorJump(appName: "Cursor"),
        EditorJump(appName: "Visual Studio Code"),
    ]

    @discardableResult public static func focus(cwd: String) -> Bool {
        for target in preferred where target.focus(cwd: cwd) { return true }
        return false
    }
}
