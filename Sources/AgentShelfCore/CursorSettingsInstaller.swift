import Foundation

/// Idempotently ensures Cursor's terminal tab *description* includes `${sequence}`, so a
/// marker `CursorTabFocuser` writes into a tty as an OSC title actually surfaces somewhere in
/// that tab's visible/accessible text. Cursor (like VS Code) defaults
/// `terminal.integrated.tabs.title` to `${process}` and
/// `terminal.integrated.tabs.description` to `${task}${separator}${local}${separator}${cwdFolder}`
/// — neither reflects OSC-set titles unless `${sequence}` is added. Without this, tagging a
/// tty is a harmless no-op and `CursorTabFocuser.focus` just returns false.
///
/// Appends `${separator}${sequence}` to whatever description template is already configured
/// (default or user-customized) rather than overwriting it — same "preserve everything else"
/// approach as `StatusLineInstaller`. Idempotent: a no-op once `${sequence}` is already present
/// for any reason. Uninstall restores the exact prior value (or removes the key if it was never
/// set) via a sidecar file, mirroring `StatusLineInstaller`'s original-value backup.
public struct CursorSettingsInstaller {
    public let settingsURL: URL
    public let originalURL: URL   // sidecar holding the prior value verbatim, for byte-exact-ish uninstall
    private static let key = "terminal.integrated.tabs.description"
    private static let defaultDescription = "${task}${separator}${local}${separator}${cwdFolder}"
    private static let suffix = "${separator}${sequence}"

    public static var defaultSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/settings.json")
    }

    public static var defaultSupportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentShelf")
    }

    public init(settingsURL: URL? = nil, supportDir: URL? = nil) {
        self.settingsURL = settingsURL ?? Self.defaultSettingsURL
        let dir = supportDir ?? Self.defaultSupportDir
        self.originalURL = dir.appendingPathComponent("cursor-tabs-description-original.json")
    }

    public func isInstalled() throws -> Bool {
        let (root, _) = try SettingsFile.load(settingsURL)
        return ((root[Self.key] as? String) ?? "").contains("${sequence}")
    }

    public func install() throws {
        var (root, _) = try SettingsFile.load(settingsURL)
        let current = root[Self.key] as? String
        guard !(current ?? "").contains("${sequence}") else { return }   // already good

        if !FileManager.default.fileExists(atPath: originalURL.path) {
            try SettingsFile.write(SettingsFile.serialize(["original": current ?? NSNull()]), to: originalURL)
        }
        root[Self.key] = (current ?? Self.defaultDescription) + Self.suffix
        try SettingsFile.write(SettingsFile.serialize(root), to: settingsURL)
    }

    public func uninstall() throws {
        defer { cleanupSidecar() }
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        var (root, _) = try SettingsFile.load(settingsURL)
        guard let data = try? Data(contentsOf: originalURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let original = obj["original"] as? String {
            root[Self.key] = original
        } else {
            root.removeValue(forKey: Self.key)
        }
        try SettingsFile.write(SettingsFile.serialize(root), to: settingsURL)
    }

    private func cleanupSidecar() { try? FileManager.default.removeItem(at: originalURL) }
}
