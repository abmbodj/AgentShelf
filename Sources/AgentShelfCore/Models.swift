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

/// Supported agents. Extension seam: adding an agent is a new case + capability.
public enum AgentSource: String, Codable, Sendable, CaseIterable {
    case claudeCode
    case codex
    case geminiCLI
    case cursor

    public var capability: Capability {
        switch self {
        case .claudeCode: return .fullApproval
        default: return .monitorOnly
        }
    }

    public var displayName: String {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        case .geminiCLI: return "gemini"
        case .cursor: return "cursor"
        }
    }
}

public enum SessionStatus: String, Codable, Sendable {
    case running          // agent is working
    case waitingApproval  // a PermissionRequest is pending
    case idle             // waiting for user input
    case done             // session ended
    case error

    /// Higher = more urgent; the pill shows the worst status across sessions.
    public var severity: Int {
        switch self {
        case .waitingApproval: return 3
        case .error: return 2
        case .running: return 1
        case .idle, .done: return 0
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
