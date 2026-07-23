import Foundation

public enum AgentShelf {
    /// In App Support, not /tmp: macOS periodically cleans /tmp and would delete the
    /// bound socket file out from under a long-running app.
    public static let socketPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AgentShelf/agentshelf.sock").path

    /// Approval deadline chain, outermost first — each stage must resolve before the
    /// outer one kills it (every expiry fails OPEN back to Claude's own prompt):
    /// settings.json entry timeout > hook's wait on the app > app's wait on the user.
    public static let hookEntryTimeout = 86_400                    // written to settings.json
    public static let hookDecisionTimeout: TimeInterval = 86_100   // hook blocks on socket
    public static let appDecisionTimeout: TimeInterval = 85_800    // app blocks on the user
}

/// What an agent integration can do. Gates whether the notch shows approve/deny.
public enum Capability: String, Codable, Sendable {
    case fullApproval   // status + blocking PermissionRequest (Claude Code)
    case monitorOnly    // status/notify only, no approval surface
}

/// Supported agents. Metadata (display name, capability, process match, log source) lives in
/// AgentRegistry — a case here is just the stable, Codable key. The rawValues of the original
/// four are unchanged so already-persisted sessions.json still decodes.
public enum AgentSource: String, Codable, Sendable, CaseIterable {
    case claudeCode, codex, zcode, geminiCLI, antigravityCLI, cursor, trae, openCode
    case mimoCode, droid, qoder, qwen, grokBuild, kimiCode, deepSeek, mistralVibe
    case copilot, codeBuddy, workBuddy, kiro, hermes, amp, piAgent, ohMyPi, gajaeCode, kimi

    /// .fullApproval only for agents whose tier can answer a blocking permission (Claude Code).
    public var capability: Capability {
        AgentRegistry.integration(for: self).tier == .fullApproval ? .fullApproval : .monitorOnly
    }

    public var displayName: String { AgentRegistry.integration(for: self).displayName }
}

public enum SessionStatus: String, Codable, Sendable {
    case running          // agent is working
    case waitingApproval  // a PermissionRequest is pending
    case idle             // waiting for user input
    case error

    /// Higher = more urgent; the pill shows the worst status across sessions.
    public var severity: Int {
        switch self {
        case .waitingApproval: return 3
        case .error: return 2
        case .running: return 1
        case .idle: return 0
        }
    }
}

public struct Session: Codable, Identifiable, Sendable {
    public let id: String            // Claude Code session_id (or agent_id for a subagent)
    public var source: AgentSource
    public var cwd: String
    public var status: SessionStatus
    public var startedAt: Date
    public var lastActivity: Date
    public var parentId: String?     // set = this row is a subagent of parentId
    public var agentType: String?    // subagent label, e.g. "explore" / "code-reviewer"
    public var lastTool: String?     // most recent tool name, shown as the row's activity hint
    public var lastToolSummary: String?  // file path / command for lastTool, for activityLabel
    public var terminal: String?     // TERM_PROGRAM the session's hook last reported
    public var tty: String?          // controlling terminal device path the hook last reported
    // Prompt text stays off disk: omitted from CodingKeys below, defaults to nil on restore.
    public var lastUserPrompt: String?

    public init(id: String, source: AgentSource, cwd: String,
                status: SessionStatus, startedAt: Date = .now, lastActivity: Date = .now,
                parentId: String? = nil, agentType: String? = nil) {
        self.id = id
        self.source = source
        self.cwd = cwd
        self.status = status
        self.startedAt = startedAt
        self.lastActivity = lastActivity
        self.parentId = parentId
        self.agentType = agentType
    }

    enum CodingKeys: String, CodingKey {
        case id, source, cwd, status, startedAt, lastActivity, parentId, agentType
        case lastTool, lastToolSummary, terminal, tty
        // lastUserPrompt intentionally omitted.
    }

    /// Last path component of cwd — the repo/folder label shown in a row.
    public var folderName: String {
        (cwd as NSString).lastPathComponent
    }

    public var isSubagent: Bool { parentId != nil }

    /// Compact session age for the row: "<1m", "12m", "2h", "3d".
    public var ageLabel: String {
        let s = Int(Date.now.timeIntervalSince(startedAt))
        if s < 60 { return "<1m" }
        if s < 3_600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3_600)h" }
        return "\(s / 86_400)d"
    }

    /// Row label: the agent type for a subagent, else the source name ("claude").
    public var displayLabel: String { agentType ?? source.displayName }

    /// Short terminal badge from TERM_PROGRAM, or nil if unknown/not yet reported.
    public var terminalLabel: String? {
        switch terminal {
        case "iTerm.app": return "iTerm"
        case "Apple_Terminal": return "Terminal"
        case "ghostty": return "Ghostty"
        case "vscode": return "VS Code"
        case let other?: return other
        case nil: return nil
        }
    }

    /// Friendly current action derived from the last tool, for the row's activity subline
    /// ("Writing middleware.ts" rather than the raw tool name "Edit").
    public var activityLabel: String? {
        guard let lastTool else { return nil }
        let file = lastToolSummary.map { ($0 as NSString).lastPathComponent }
        switch lastTool {
        case "Write": return "Writing \(file ?? "file")"
        case "Edit", "MultiEdit": return "Editing \(file ?? "file")"
        case "Read": return "Reading \(file ?? "file")"
        case "Bash": return lastToolSummary.map { "Running \($0)" } ?? "Running command"
        case "Grep", "Glob": return "Searching"
        case "AskUserQuestion": return "Asking a question"
        default: return lastTool
        }
    }

    /// Order sessions so each subagent renders directly under its parent, preserving the
    /// input order of top-level rows. Orphans (parent already gone) fall back to top-level.
    public static func nested(_ sessions: [Session]) -> [Session] {
        let byParent = Dictionary(grouping: sessions.filter { $0.parentId != nil }, by: { $0.parentId! })
        let present = Set(sessions.map(\.id))
        var out: [Session] = []
        for s in sessions where s.parentId == nil || !present.contains(s.parentId!) {
            out.append(s)
            out.append(contentsOf: byParent[s.id] ?? [])
        }
        return out
    }
}
