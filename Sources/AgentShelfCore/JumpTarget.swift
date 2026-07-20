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
