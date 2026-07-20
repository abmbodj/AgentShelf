import SwiftUI
import AgentShelfCore

/// Owns all session state on the main actor. Socket messages are applied here.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    private var index: [String: Int] = [:]

    /// Map a hook event to the status it implies (nil = leave status unchanged).
    static func status(for event: String) -> SessionStatus? {
        switch event {
        case "SessionStart", "Stop", "SubagentStop": return .idle
        case "UserPromptSubmit", "PreToolUse", "PostToolUse": return .running
        case "PermissionRequest": return .waitingApproval
        default: return nil
        }
    }

    func apply(_ msg: HookMessage) {
        let newStatus = Self.status(for: msg.event)
        if let i = index[msg.sessionId] {
            if let newStatus { sessions[i].status = newStatus }
            sessions[i].lastActivity = .now
        } else {
            index[msg.sessionId] = sessions.count
            sessions.append(Session(id: msg.sessionId, source: msg.source,
                                    cwd: msg.cwd, status: newStatus ?? .idle))
        }
    }

    /// Sessions worth showing. (Liveness-based pruning is a Phase 2 concern.)
    var active: [Session] { sessions }

    var worstStatus: SessionStatus? {
        active.max { $0.status.severity < $1.status.severity }?.status
    }
}

extension SessionStatus {
    var color: Color {
        switch self {
        case .waitingApproval: return .orange
        case .error: return .red
        case .running: return .green
        case .idle, .done: return .secondary
        }
    }

    var label: String {
        switch self {
        case .waitingApproval: return "needs approval"
        case .running: return "running"
        case .idle: return "idle"
        case .done: return "done"
        case .error: return "error"
        }
    }
}
