import Foundation

/// Installs the hook CLI at a stable path outside the app bundle, so rebuilding or
/// moving the app never breaks the command already registered in settings.json.
public enum ManagedHookBinary {
    public static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentShelf/bin/agentshelf-hook")
    }

    /// Copy `source` to the managed path when missing or byte-different.
    /// Unlink-then-copy: a hook mid-run keeps its old inode, so this is safe live.
    @discardableResult
    public static func install(from source: URL) throws -> URL {
        let fm = FileManager.default
        let dest = url
        if let a = try? Data(contentsOf: dest), let b = try? Data(contentsOf: source), a == b {
            return dest
        }
        try fm.createDirectory(at: dest.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        try fm.copyItem(at: source, to: dest)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        return dest
    }
}
