import SwiftUI
import AgentShelfCore

/// Owns all session state on the main actor. Socket messages are applied here.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var pendingApprovals: [ApprovalRequest] = []
    @Published private(set) var pendingQuestions: [QuestionRequest] = []
    @Published private(set) var pendingNotices: [AttentionNotice] = []
    private var index: [String: Int] = [:]
    private var persistTask: Task<Void, Never>?

    private static let persistURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AgentShelf/sessions.json")

    init() { restore() }

    /// Recent sessions survive an app restart, coming back as idle (live status and
    /// pending approvals can't outlive the hook connections). Stale rows prune out.
    private func restore() {
        guard let data = try? Data(contentsOf: Self.persistURL),
              var restored = try? JSONDecoder().decode([Session].self, from: data),
              !restored.isEmpty else { return }
        for i in restored.indices { restored[i].status = .idle }
        sessions = restored
        reindex()
        prune()
    }

    /// Debounced write — hook events can be chatty; one save a second is plenty.
    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            try? FileManager.default.createDirectory(
                at: Self.persistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(sessions).write(to: Self.persistURL, options: .atomic)
        }
    }

    /// Every minute: when NO claude-ish process exists at all, idle rows are certainly
    /// dead — drop them without waiting out the 15-minute prune. Running rows are never
    /// touched, and pgrep over-matching only defers cleanup (the safe direction).
    func startReaper() {
        Task { @MainActor in
            while true {
                try? await Task.sleep(for: .seconds(60))
                guard !sessions.isEmpty else { continue }
                let alive = await Task.detached { Self.claudeProcessExists() }.value
                if !alive {
                    sessions.removeAll { $0.status == .idle || $0.status == .done }
                    reindex()
                    schedulePersist()
                }
            }
        }
    }

    nonisolated private static func claudeProcessExists() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "claude"]
        p.standardOutput = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
        catch { return true }   // can't tell -> assume alive, never reap blind
    }

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
            // A pending approval or question owns the status: a late running event (parallel
            // tool, subagent traffic) must never clear the waiting card from under the user.
            let waitingPending = sessions[i].status == .waitingApproval
                && (pendingApprovals.contains { $0.sessionId == msg.sessionId }
                    || pendingQuestions.contains { $0.sessionId == msg.sessionId })
            if let newStatus, !waitingPending || newStatus == .waitingApproval {
                sessions[i].status = newStatus
            }
            if let tool = msg.toolName {
                sessions[i].lastTool = tool
                sessions[i].lastToolSummary = msg.toolSummary
            }
            if let terminal = msg.terminal { sessions[i].terminal = terminal }
            if let prompt = msg.userPrompt { sessions[i].lastUserPrompt = prompt }
            sessions[i].lastActivity = .now
            isNew = false
        } else {
            index[msg.sessionId] = sessions.count
            var session = Session(id: msg.sessionId, source: msg.source,
                                  cwd: msg.cwd, status: newStatus ?? .idle,
                                  parentId: msg.parentId, agentType: msg.agentType)
            session.lastTool = msg.toolName
            session.lastToolSummary = msg.toolSummary
            session.terminal = msg.terminal
            session.lastUserPrompt = msg.userPrompt
            sessions.append(session)
            isNew = true
        }
        prune()
        schedulePersist()
        return isNew
    }

    /// The session ended (SessionEnd hook) — drop it, its subagents, and any pending attention.
    func endSession(_ id: String) {
        sessions.removeAll { $0.id == id || $0.parentId == id }
        pendingApprovals.removeAll { $0.sessionId == id }
        pendingQuestions.removeAll { $0.sessionId == id }
        pendingNotices.removeAll { $0.sessionId == id }
        reindex()
        schedulePersist()
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

    /// Show a non-blocking "needs input" prompt for a non-binary permission (a choice, not a
    /// grant). A single-question, single-select AskUserQuestion is answerable inline (waits
    /// like an approval, no auto-dismiss); anything richer falls back to a read-only notice
    /// that auto-dismisses after a few seconds — the user answers in Claude's own UI.
    /// `quiet` skips the sound (the user is already looking at the session's window).
    func presentNeedsInput(_ msg: HookMessage, quiet: Bool = false) {
        apply(msg)   // creates/updates the session, sets .waitingApproval
        guard !pendingQuestions.contains(where: { $0.sessionId == msg.sessionId }) else { return }
        if let question = QuestionRequest(message: msg, onResolve: { [weak self] in
            self?.removeQuestion(sessionId: msg.sessionId)
        }) {
            pendingQuestions.append(question)
            if !quiet { ApprovalSound.play() }
            return
        }

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

    /// Drop the pending question for a session (on answer or "Open in Claude") and un-wait it.
    func removeQuestion(sessionId: String) {
        pendingQuestions.removeAll { $0.sessionId == sessionId }
        if let i = index[sessionId], sessions[i].status == .waitingApproval {
            sessions[i].status = .running
        }
    }

    /// Sessions worth showing, ordered so each subagent renders directly under its parent.
    var active: [Session] { Session.nested(sessions) }

    /// Headline count for the pill: real sessions only, subagents don't inflate it.
    var topLevelCount: Int { sessions.filter { $0.parentId == nil }.count }

    /// True while any approval, question, or notice is waiting — drives attention-only notch.
    var hasAttention: Bool {
        !pendingApprovals.isEmpty || !pendingQuestions.isEmpty || !pendingNotices.isEmpty
    }

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
