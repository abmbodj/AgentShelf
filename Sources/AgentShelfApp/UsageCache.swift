import Foundation
import AgentShelfCore

/// Usage chips text from the statusline cache, 30s TTL — same rule as BranchCache:
/// the header renders every layout pass, never do file IO uncached in a view body.
@MainActor
enum UsageCache {
    private static var cached: (text: String?, at: Date)?

    /// "5h 42% · 7d 18%", or nil when the cache is missing/stale (> 6h old).
    static var text: String? {
        if let cached, Date.now.timeIntervalSince(cached.at) < 30 { return cached.text }
        let value = read()
        cached = (value, .now)
        return value
    }

    private static func read() -> String? {
        let url = StatusLineInstaller.defaultCacheURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date,
              Date.now.timeIntervalSince(mtime) < 6 * 3600,
              let data = try? Data(contentsOf: url) else { return nil }
        let windows = ClaudeUsage.windows(from: data)
        guard !windows.isEmpty else { return nil }
        return windows.map { "\($0.label) \($0.usedPercent)%" }.joined(separator: " · ")
    }
}
