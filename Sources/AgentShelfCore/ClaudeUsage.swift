import Foundation

/// One rate-limit window from Claude Code's statusline payload.
public struct UsageWindow: Equatable, Sendable {
    public let label: String        // "5h" / "7d"
    public let usedPercent: Int
    public init(label: String, usedPercent: Int) {
        self.label = label
        self.usedPercent = usedPercent
    }
}

public enum ClaudeUsage {
    /// Parse `rate_limits` out of a cached statusline payload. Tolerant: anything
    /// missing or misshapen just yields fewer (or no) windows.
    public static func windows(from data: Data) -> [UsageWindow] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let limits = root["rate_limits"] as? [String: Any] else { return [] }
        var out: [UsageWindow] = []
        for (key, label) in [("five_hour", "5h"), ("seven_day", "7d")] {
            guard let window = limits[key] as? [String: Any],
                  let raw = (window["used_percentage"] ?? window["utilization"]) as? Double
            else { continue }
            let pct = raw <= 1 ? raw * 100 : raw   // accept 0–1 fractions and 0–100 percents
            out.append(UsageWindow(label: label, usedPercent: Int(pct.rounded())))
        }
        return out
    }
}
