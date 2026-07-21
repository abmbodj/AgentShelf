import Foundation

/// Checks GitHub Releases for a newer AgentShelf version than the one currently running.
/// No auto-download — just tells the menu bar whether to show a link to the release page.
public enum UpdateChecker {
    public struct Release: Sendable {
        public let tag: String       // e.g. "v0.2.0"
        public let htmlURL: URL
    }

    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/abmbodj/AgentShelf/releases/latest")!

    /// Fetches the latest published release. Returns nil on any failure (offline, rate-limited,
    /// no releases yet) — an update check should never be loud about network trouble.
    public static func fetchLatest() async -> Release? {
        guard let (data, _) = try? await URLSession.shared.data(from: latestReleaseURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String,
              let urlString = root["html_url"] as? String,
              let url = URL(string: urlString)
        else { return nil }
        return Release(tag: tag, htmlURL: url)
    }

    /// True if `tag` (e.g. "v0.2.0") is newer than `currentVersion` (e.g. CFBundleShortVersionString
    /// "0.1.0"). Compares dotted numeric components; malformed input is treated as not-newer
    /// (fail closed — never nag about an update that isn't real).
    public static func isNewer(_ tag: String, than currentVersion: String) -> Bool {
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let latestParts = latest.split(separator: ".").compactMap { Int($0) }
        let currentParts = currentVersion.split(separator: ".").compactMap { Int($0) }
        guard !latestParts.isEmpty, !currentParts.isEmpty else { return false }
        for i in 0..<max(latestParts.count, currentParts.count) {
            let l = i < latestParts.count ? latestParts[i] : 0
            let c = i < currentParts.count ? currentParts[i] : 0
            if l != c { return l > c }
        }
        return false
    }
}
