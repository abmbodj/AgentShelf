import Foundation

public enum AgentShelf {
    public static let socketPath = "/tmp/agentshelf.sock"
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
    var severity: Int {
        switch self {
        case .waitingApproval: return 3
        case .error: return 2
        case .running: return 1
        case .idle, .done: return 0
        }
    }
}

public struct Session: Codable, Identifiable, Sendable {
    public let id: String            // Claude Code session_id (or agent_id for subagents)
    public var source: AgentSource
    public var cwd: String
    public var status: SessionStatus
    public var startedAt: Date
    public var lastActivity: Date

    public init(id: String, source: AgentSource, cwd: String,
                status: SessionStatus, startedAt: Date = .now, lastActivity: Date = .now) {
        self.id = id
        self.source = source
        self.cwd = cwd
        self.status = status
        self.startedAt = startedAt
        self.lastActivity = lastActivity
    }

    /// Last path component of cwd — the repo/folder label shown in a row.
    public var folderName: String {
        (cwd as NSString).lastPathComponent
    }
}
