import Foundation

/// Best-effort activity enrichment for .richMonitor agents. Given a running agent's log dir,
/// finds the newest session file and pulls the last tool/file out of it, so a monitor row can
/// show "Editing foo.ts" like a hook-fed one. Purely additive and fail-safe: no file, an
/// unreadable file, or an unknown schema just yields nil and the row stays plain running/idle.
public enum SessionLogTailer {
    public struct Activity: Sendable, Equatable {
        public let tool: String?
        public let summary: String?
    }

    /// Common key spellings across agents' logs — we don't know each schema, so we probe a
    /// small superset. ponytail: probe list, not per-agent parsers; add a case only if a real
    /// log needs one these miss.
    private static let toolKeys = ["tool_name", "toolName", "tool", "name", "type"]
    private static let fileKeys = ["file_path", "filePath", "path", "file", "command", "summary", "cwd"]

    /// Enrich a hit whose agent has a logSource. Returns nil for presence-tier agents or when
    /// nothing usable is found.
    public static func activity(for source: AgentSource, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Activity? {
        guard let log = AgentRegistry.integration(for: source).logSource else { return nil }
        let dir = home.appendingPathComponent(log.dir)
        guard let newest = newestFile(in: dir, ext: log.ext) else { return nil }
        // ponytail: reads the whole file; session logs are small in practice. Seek-tail if a
        // long-lived log ever makes this hot.
        guard let text = try? String(contentsOf: newest, encoding: .utf8) else { return nil }
        guard let record = lastRecord(text, ext: log.ext) else { return nil }
        let tool = firstString(record, keys: toolKeys)
        let summary = firstString(record, keys: fileKeys)
        guard tool != nil || summary != nil else { return nil }
        return Activity(tool: tool, summary: summary)
    }

    /// Newest regular file with the given extension under `dir` (searched one level deep too,
    /// since some agents nest per-project subdirs). Returns nil if the dir is absent/empty.
    static func newestFile(in dir: URL, ext: String) -> URL? {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                     options: [.skipsHiddenFiles]) else { return nil }
        var best: (URL, Date)?
        for case let url as URL in en where url.pathExtension == ext {
            let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard vals?.isRegularFile == true, let mod = vals?.contentModificationDate else { continue }
            if best == nil || mod > best!.1 { best = (url, mod) }
        }
        return best?.0
    }

    /// The last meaningful JSON object in a log. For jsonl, the last non-empty line; for a json
    /// file, the root object or the last element if it's an array.
    static func lastRecord(_ text: String, ext: String) -> [String: Any]? {
        if ext == "jsonl" {
            for line in text.split(separator: "\n").reversed() {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty, let obj = try? JSONSerialization.jsonObject(with: Data(t.utf8)) else { continue }
                if let dict = obj as? [String: Any] { return dict }
            }
            return nil
        }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return nil }
        if let dict = obj as? [String: Any] { return dict }
        if let arr = obj as? [Any] { return arr.reversed().compactMap { $0 as? [String: Any] }.first }
        return nil
    }

    /// First present string value among `keys`, searched one level into nested dicts too
    /// (many logs wrap the payload, e.g. {"message": {"tool_name": ...}}).
    private static func firstString(_ record: [String: Any], keys: [String]) -> String? {
        for key in keys { if let s = record[key] as? String, !s.isEmpty { return s } }
        for value in record.values {
            if let nested = value as? [String: Any] {
                for key in keys { if let s = nested[key] as? String, !s.isEmpty { return s } }
            }
        }
        return nil
    }
}
