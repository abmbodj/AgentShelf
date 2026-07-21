import Foundation

/// Wraps the user's Claude Code statusLine so usage data flows to the shelf while their
/// own statusline renders unchanged: the wrapper tees the payload to a cache file, then
/// runs the original command with stdin forwarded verbatim.
///
/// Same HARD RULES as ClaudeInstaller: refuses unparseable configs, idempotent install,
/// never wraps its own wrapper, and uninstall restores the original statusLine —
/// byte-for-byte when nothing else changed.
public struct StatusLineInstaller {
    public let settingsURL: URL
    public let wrapperURL: URL    // generated bash wrapper (name carries the marker)
    public let cacheURL: URL      // where the wrapper tees the statusline payload

    /// Any command we own contains this marker (it's the wrapper's file name).
    static let marker = "agentshelf-statusline"

    public static var defaultSupportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentShelf")
    }
    public static var defaultCacheURL: URL {
        defaultSupportDir.appendingPathComponent("statusline.json")
    }

    public init(settingsURL: URL? = nil, supportDir: URL? = nil) {
        self.settingsURL = settingsURL ?? ClaudeInstaller.defaultSettingsURL
        let dir = supportDir ?? Self.defaultSupportDir
        self.wrapperURL = dir.appendingPathComponent("bin/\(Self.marker)")
        self.cacheURL = dir.appendingPathComponent("statusline.json")
    }

    private var backupURL: URL { settingsURL.appendingPathExtension("agentshelf-statusline-backup") }
    /// Sidecar holding the original statusLine value verbatim ({"original": <value|null>}),
    /// so uninstall can restore it even if the settings file changed around it.
    private var originalURL: URL { wrapperURL.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("statusline-original.json") }

    // MARK: Public API

    public func isInstalled() throws -> Bool {
        let (root, _) = try SettingsFile.load(settingsURL)
        return Self.commandIsOurs(root["statusLine"])
    }

    public func install() throws {
        let (root, originalBytes) = try SettingsFile.load(settingsURL)
        let current = root["statusLine"] as? [String: Any]

        if Self.commandIsOurs(root["statusLine"]) {
            // Already installed: just regenerate the wrapper (self-upgrade), never re-wrap.
            try writeWrapper(originalCommand: storedOriginalCommand())
            return
        }

        // Back up the original bytes once, so uninstall can restore byte-for-byte.
        if let originalBytes, !FileManager.default.fileExists(atPath: backupURL.path) {
            try SettingsFile.write(originalBytes, to: backupURL)
        }
        try SettingsFile.write(SettingsFile.serialize(["original": current ?? NSNull()]),
                               to: originalURL)
        try writeWrapper(originalCommand: current?["command"] as? String)

        // Preserve every other statusLine attribute (padding etc.) — only swap the command.
        var statusLine = current ?? ["type": "command"]
        statusLine["command"] = "'\(wrapperURL.path)'"
        var newRoot = root
        newRoot["statusLine"] = statusLine
        try SettingsFile.write(SettingsFile.serialize(newRoot), to: settingsURL)
    }

    public func uninstall() throws {
        var (root, _) = try SettingsFile.load(settingsURL)
        if Self.commandIsOurs(root["statusLine"]) {
            if let original = storedOriginal() {
                root["statusLine"] = original
            } else {
                root.removeValue(forKey: "statusLine")   // there was none before us
            }
            // Byte-exact restore when removing us reproduces the backed-up config.
            let cleaned = SettingsFile.serialize(root)
            if let backup = try? Data(contentsOf: backupURL),
               SettingsFile.normalized(cleaned) == SettingsFile.normalized(backup) {
                try SettingsFile.write(backup, to: settingsURL)
            } else {
                try SettingsFile.write(cleaned, to: settingsURL)
            }
        }
        for url in [wrapperURL, originalURL, backupURL, cacheURL] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Helpers

    static func commandIsOurs(_ statusLine: Any?) -> Bool {
        ((statusLine as? [String: Any])?["command"] as? String)?.contains(marker) ?? false
    }

    /// The original statusLine value from the sidecar (nil = there was none / no sidecar).
    private func storedOriginal() -> [String: Any]? {
        guard let data = try? Data(contentsOf: originalURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["original"] as? [String: Any]
    }

    private func storedOriginalCommand() -> String? {
        storedOriginal()?["command"] as? String
    }

    private func writeWrapper(originalCommand: String?) throws {
        // No original statusline: print a minimal "[model]" line so the user isn't left
        // with a blank bar (python3 is everywhere Claude Code runs; degrade to silence).
        let delegate = originalCommand
            ?? #"/usr/bin/python3 -c 'import json,sys;print("["+json.load(sys.stdin).get("model",{}).get("display_name","claude")+"]")' 2>/dev/null || true"#
        let script = """
        #!/bin/bash
        # \(Self.marker): caches Claude Code's statusline payload so Agent Shelf can show
        # usage, then runs the user's own statusline unchanged (stdin forwarded verbatim).
        # Managed by Agent Shelf — do not edit; uninstall restores the original statusLine.
        CACHE='\(cacheURL.path)'
        TMP="$CACHE.$$"
        tee "$TMP" | \(delegate)
        STATUS=$?
        mv -f "$TMP" "$CACHE" 2>/dev/null
        exit $STATUS
        """
        try SettingsFile.write(Data((script + "\n").utf8), to: wrapperURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: wrapperURL.path)
    }
}
