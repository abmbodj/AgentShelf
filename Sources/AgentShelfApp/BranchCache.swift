import Foundation

/// Git branch for a cwd, cached 30s. Rows render every layout pass — the uncached
/// walk-and-read was upstream's 99%-CPU incident, hence the TTL.
@MainActor
enum BranchCache {
    private static var cache: [String: (value: String?, at: Date)] = [:]

    static func branch(for cwd: String) -> String? {
        if let hit = cache[cwd], Date.now.timeIntervalSince(hit.at) < 30 { return hit.value }
        let value = resolve(cwd: cwd)
        cache[cwd] = (value, .now)
        return value
    }

    /// Walk up from cwd to the repo root, then read HEAD. Handles worktrees
    /// (`.git` file with a `gitdir:` pointer) and detached HEAD (short sha).
    private static func resolve(cwd: String) -> String? {
        var dir = URL(fileURLWithPath: cwd)
        for _ in 0..<12 {
            let dotGit = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                let gitDir: URL
                if isDir.boolValue {
                    gitDir = dotGit
                } else if let text = try? String(contentsOf: dotGit, encoding: .utf8),
                          let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) {
                    let p = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    gitDir = p.hasPrefix("/") ? URL(fileURLWithPath: p) : dir.appendingPathComponent(p)
                } else {
                    return nil
                }
                guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"),
                                             encoding: .utf8) else { return nil }
                let t = head.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.hasPrefix("ref: refs/heads/")
                    ? String(t.dropFirst("ref: refs/heads/".count))
                    : String(t.prefix(7))
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
        return nil
    }
}
