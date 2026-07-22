import Foundation

/// Resolves the *calling* process's controlling terminal device path (e.g. "/dev/ttys004").
/// Captured directly by the hook, not inferred — this is the exact pty Claude Code's
/// interactive session (raw-mode menus included) is attached to, regardless of what the
/// hook's own stdin/stdout are wired to (Claude Code redirects those to pass the JSON payload
/// and read the hook's reply). Best-effort: nil with no controlling terminal (headless run,
/// CI, etc.) — hooks must never fail because of this (see agentshelf-hook's hard rules).
public enum ControllingTTY {
    public static func path() -> String? {
        let fd = open("/dev/tty", O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard let namePtr = ttyname(fd) else { return nil }
        return String(cString: namePtr)
    }
}
