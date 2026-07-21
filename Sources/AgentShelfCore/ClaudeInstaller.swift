import Foundation

public enum InstallerError: Error, Equatable {
    case unparseable(String)   // existing config isn't valid JSON — refuse, change nothing
    case io(String)
}

/// Surgically installs/removes the agentshelf-hook entries in a Claude Code settings.json.
///
/// HARD RULES (see project memory):
/// - only ever adds/removes OUR hook entries (identified by "agentshelf-hook" in the command)
/// - never touches statusLine, output styles, or any hook it didn't add
/// - refuses to touch a config it can't fully parse (throws, writes nothing)
/// - idempotent install; uninstall restores the file byte-for-byte when nothing else changed
public struct ClaudeInstaller {
    public let settingsURL: URL
    public let hookCommand: String   // e.g. "/abs/path/agentshelf-hook claudeCode"

    /// One binary handles every event (Claude Code passes hook_event_name on stdin).
    /// `true` = tool-matched event (needs a "*" matcher), `false` = plain event.
    static let events: [(name: String, tool: Bool)] = [
        ("SessionStart", false),
        ("UserPromptSubmit", false),
        ("PreToolUse", true),
        ("PermissionRequest", true),
        ("Stop", false),
        ("SessionEnd", false),   // remove the session from the shelf when it truly ends
    ]

    /// Any command we own contains this marker, so uninstall finds our entries even if the
    /// binary path changed between install and uninstall.
    static let marker = "agentshelf-hook"

    public init(settingsURL: URL? = nil, hookCommand: String) {
        self.settingsURL = settingsURL ?? Self.defaultSettingsURL
        self.hookCommand = hookCommand
    }

    public static var defaultSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    private var backupURL: URL { settingsURL.appendingPathExtension("agentshelf-backup") }

    // MARK: Read/parse

    /// Returns the parsed root, or [:] if the file is missing. Throws if it exists but is
    /// unparseable — we never partially write a config we don't fully understand.
    private func loadRoot() throws -> (root: [String: Any], originalBytes: Data?) {
        guard let bytes = try? Data(contentsOf: settingsURL) else { return ([:], nil) }
        guard let obj = try? JSONSerialization.jsonObject(with: bytes),
              let root = obj as? [String: Any] else {
            throw InstallerError.unparseable(settingsURL.path)
        }
        return (root, bytes)
    }

    private func groups(_ hooks: [String: Any], _ event: String) -> [[String: Any]] {
        (hooks[event] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    private func groupContainsOurs(_ group: [String: Any]) -> Bool {
        let inner = (group["hooks"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        return inner.contains { ($0["command"] as? String)?.contains(Self.marker) ?? false }
    }

    // MARK: Public API

    public func isInstalled() throws -> Bool {
        let (root, _) = try loadRoot()
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        return Self.events.contains { groups(hooks, $0.name).contains(where: groupContainsOurs) }
    }

    public func install() throws {
        var (root, originalBytes) = try loadRoot()
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        for (event, isTool) in Self.events {
            var evGroups = groups(hooks, event)
            if evGroups.contains(where: groupContainsOurs) { continue }   // idempotent
            let commandHook: [String: Any] = ["type": "command", "command": hookCommand]
            var group: [String: Any] = ["hooks": [commandHook]]
            if isTool { group["matcher"] = "*" }
            evGroups.append(group)
            hooks[event] = evGroups
        }
        root["hooks"] = hooks

        // Back up the original bytes once, so uninstall can restore byte-for-byte.
        if let originalBytes, !FileManager.default.fileExists(atPath: backupURL.path) {
            try write(originalBytes, to: backupURL)
        }
        try write(serialize(root), to: settingsURL)
    }

    public func uninstall() throws {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        var (root, _) = try loadRoot()
        guard var hooks = root["hooks"] as? [String: Any] else { cleanupBackup(); return }

        for (event, _) in Self.events {
            let cleaned = groups(hooks, event).compactMap { group -> [String: Any]? in
                var group = group
                let inner = (group["hooks"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
                let kept = inner.filter { !(($0["command"] as? String)?.contains(Self.marker) ?? false) }
                if kept.isEmpty { return nil }        // group held only our hook -> drop it
                group["hooks"] = kept                 // group had foreign hooks too -> keep them
                return group
            }
            if cleaned.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = cleaned }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }

        // Byte-exact restore: if removing our entries reproduces the backed-up config,
        // write the original bytes verbatim rather than a reserialized version.
        let cleanedBytes = serialize(root)
        if let backup = try? Data(contentsOf: backupURL),
           normalized(cleanedBytes) == normalized(backup) {
            try write(backup, to: settingsURL)
        } else {
            try write(cleanedBytes, to: settingsURL)
        }
        cleanupBackup()
    }

    // MARK: Helpers

    private func serialize(_ root: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    }

    private func normalized(_ data: Data) -> Data? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }

    private func write(_ data: Data, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch { throw InstallerError.io("\(url.path): \(error)") }
    }

    private func cleanupBackup() { try? FileManager.default.removeItem(at: backupURL) }
}
