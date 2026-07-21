import SwiftUI
import AgentShelfCore

/// Owns all session state on the main actor. Socket messages are applied here.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var pendingApprovals: [ApprovalRequest] = []
    @Published private(set) var pendingNotices: [AttentionNotice] = []
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

    /// Returns true if this created a new session (so the UI can flash to announce it).
    @discardableResult
    func apply(_ msg: HookMessage) -> Bool {
        let newStatus = Self.status(for: msg.event)
        let isNew: Bool
        if let i = index[msg.sessionId] {
            // A pending approval owns the status: a late running event (parallel tool,
            // subagent traffic) must never clear the waiting card from under the user.
            let approvalPending = sessions[i].status == .waitingApproval
                && pendingApprovals.contains { $0.sessionId == msg.sessionId }
            if let newStatus, !approvalPending || newStatus == .waitingApproval {
                sessions[i].status = newStatus
            }
            if let tool = msg.toolName { sessions[i].lastTool = tool }
            sessions[i].lastActivity = .now
            isNew = false
        } else {
            index[msg.sessionId] = sessions.count
            var session = Session(id: msg.sessionId, source: msg.source,
                                  cwd: msg.cwd, status: newStatus ?? .idle,
                                  parentId: msg.parentId, agentType: msg.agentType)
            session.lastTool = msg.toolName
            sessions.append(session)
            isNew = true
        }
        prune()
        return isNew
    }

    /// The session ended (SessionEnd hook) — drop it, its subagents, and any pending attention.
    func endSession(_ id: String) {
        sessions.removeAll { $0.id == id || $0.parentId == id }
        pendingApprovals.removeAll { $0.sessionId == id }
        pendingNotices.removeAll { $0.sessionId == id }
        reindex()
    }

    /// Keep the list bounded: drop long-idle sessions (safety net for sessions that never
    /// emit SessionEnd, e.g. a crash) and cap the total.
    private func prune() {
        let cutoff = Date.now.addingTimeInterval(-15 * 60)
        let before = sessions.count
        sessions.removeAll { ($0.status == .idle || $0.status == .done) && $0.lastActivity < cutoff }
        if sessions.count > 15 {
            sessions = Array(sessions.sorted { $0.lastActivity > $1.lastActivity }.prefix(15))
        }
        if sessions.count != before { reindex() }
    }

    private func reindex() {
        index.removeAll(keepingCapacity: true)
        for (i, s) in sessions.enumerated() { index[s.id] = i }
    }

    /// Show a pending permission request and mark the session as waiting. `onDecide` is
    /// called when the user (or a timeout) resolves it; nil = hand back to Claude's UI.
    func presentApproval(_ msg: HookMessage, onDecide: @escaping (Decision?) -> Void) {
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

    /// Show a non-blocking "needs input" notice for a non-binary prompt (a choice, not a
    /// grant). Auto-dismisses after a few seconds — the user answers in Claude's own UI.
    /// `quiet` skips the sound (the user is already looking at the session's window).
    func presentNeedsInput(_ msg: HookMessage, quiet: Bool = false) {
        apply(msg)
        guard !pendingNotices.contains(where: { $0.sessionId == msg.sessionId }) else { return }
        let notice = AttentionNotice(message: msg)
        pendingNotices.append(notice)
        if !quiet { ApprovalSound.play() }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            pendingNotices.removeAll { $0.id == notice.id }
            // Clear the waiting state so the pill/notch don't stay stuck open.
            if let i = index[msg.sessionId], sessions[i].status == .waitingApproval {
                sessions[i].status = .running
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

    /// Sessions worth showing, ordered so each subagent renders directly under its parent.
    var active: [Session] { Session.nested(sessions) }

    /// Headline count for the pill: real sessions only, subagents don't inflate it.
    var topLevelCount: Int { sessions.filter { $0.parentId == nil }.count }

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
