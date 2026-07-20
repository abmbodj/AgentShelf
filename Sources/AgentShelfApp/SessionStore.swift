import SwiftUI
import AgentShelfCore

/// Owns all session state on the main actor. Socket messages are applied here.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var pendingApprovals: [ApprovalRequest] = []
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

    /// Show a pending permission request and mark the session as waiting. `onDecide` is
    /// called when the user (or a timeout) resolves it.
    func presentApproval(_ msg: HookMessage, onDecide: @escaping (Decision) -> Void) {
        apply(msg)   // creates/updates the session, sets .waitingApproval
        let req = ApprovalRequest(message: msg) { [weak self] decision in
            onDecide(decision)
            self?.removeApproval(sessionId: msg.sessionId)
        }
        pendingApprovals.append(req)
        ApprovalSound.play()

        // Test hook: auto-resolve so the wire round-trip is verifiable without a UI click.
        if let auto = ProcessInfo.processInfo.environment["AGENTSHELF_DEBUG_AUTODECIDE"],
           let behavior = Decision.Behavior(rawValue: auto) {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                req.decide(behavior)
            }
        }
    }

    /// Drop the pending approval for a session (on decision or timeout) and un-wait it.
    func removeApproval(sessionId: String) {
        pendingApprovals.removeAll { $0.sessionId == sessionId }
        if let i = index[sessionId], sessions[i].status == .waitingApproval {
            sessions[i].status = .running
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
