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

    /// The monitor/reaper cadence. Also detects newly launched monitor-tier agents, so it's the
    /// latency for a non-hook agent to appear — kept snappy. ponytail: fixed 4s; a notch-expanded
    /// burst mode could go faster, but ps/lsof are cheap enough that one interval is simpler.
    private static let monitorInterval = 4

    /// Every tick: sweep for running agents (ProcessMonitor) and reconcile their synthetic rows,
    /// re-run prune()'s long-silence settle, and — when NO agent process exists at all — drop
    /// idle rows without waiting out the 15-minute prune. Over-matching only defers cleanup
    /// (the safe direction). Runs even when `sessions` is empty, to pick up a freshly started agent.
    func startReaper() {
        Task { @MainActor in
            while true {
                try? await Task.sleep(for: .seconds(Self.monitorInterval))
                let updates = await Task.detached { Self.gatherMonitorUpdates() }.value
                reconcileMonitor(updates)
                prune()
                if updates.isEmpty {   // no agent running at all -> idle rows are certainly dead
                    let hadIdle = sessions.contains { $0.status == .idle }
                    sessions.removeAll { $0.status == .idle }
                    if hadIdle { reindex() }
                }
                schedulePersist()
            }
        }
    }

    /// One synthetic-row update: a detected process plus any activity tailed from its log.
    /// `isFresh` means the log was written recently enough to count as live work — process
    /// alive alone is not enough (a new session sitting at a prompt must stay idle).
    struct MonitorUpdate: Sendable {
        let hit: MonitorHit
        let tool: String?
        let summary: String?
        let isFresh: Bool
    }

    /// Off-actor: scan processes, then enrich richMonitor hits with their latest log activity.
    nonisolated private static func gatherMonitorUpdates() -> [MonitorUpdate] {
        ProcessMonitor.scan().map { hit in
            let act = SessionLogTailer.activity(for: hit.source)
            return MonitorUpdate(hit: hit, tool: act?.tool, summary: act?.summary,
                                 isFresh: act?.isFresh() ?? false)
        }
    }

    /// Reconcile process-detected rows: add/refresh a `proc:*` row per live agent, drop ones whose
    /// process is gone, and never shadow a hook-fed session for the same agent+folder (Claude
    /// Code's richer row always wins, so a claude process doesn't double-count).
    /// New rows start idle; only fresh log activity promotes to running (presence-tier /
    /// Claude-before-hooks stay idle until real work evidence arrives).
    func reconcileMonitor(_ updates: [MonitorUpdate]) {
        let hookCovered = Set(sessions.filter { !$0.id.hasPrefix("proc:") }
            .map { "\($0.source.rawValue)|\($0.cwd)" })
        let kept = updates.filter { !hookCovered.contains("\($0.hit.source.rawValue)|\($0.hit.cwd)") }
        let liveIds = Set(kept.map { $0.hit.sessionId })

        sessions.removeAll { $0.id.hasPrefix("proc:") && !liveIds.contains($0.id) }
        for u in kept {
            if let i = index[u.hit.sessionId] {
                let state = SessionLogTailer.rowState(isFresh: u.isFresh, priorHasRun: sessions[i].hasRun)
                sessions[i].status = state.status
                sessions[i].hasRun = state.hasRun
                if state.applyToolLabels {
                    if let t = u.tool { sessions[i].lastTool = t }
                    if let s = u.summary { sessions[i].lastToolSummary = s }
                }
                sessions[i].lastActivity = .now
            } else {
                let state = SessionLogTailer.rowState(isFresh: u.isFresh)
                var session = Session(id: u.hit.sessionId, source: u.hit.source, cwd: u.hit.cwd,
                                      status: state.status)
                session.hasRun = state.hasRun
                if state.applyToolLabels {
                    session.lastTool = u.tool
                    session.lastToolSummary = u.summary
                }
                sessions.append(session)
            }
        }
        reindex()
    }

    /// Map a hook event to the status it implies (nil = leave status unchanged).
    /// `SubagentStop` never reaches here — it's routed straight to `endSession` (a subagent
    /// is terminal, so there's no idle state worth representing for it).
    static func status(for event: String) -> SessionStatus? {
        switch event {
        case "SessionStart", "Stop": return .idle
        case "UserPromptSubmit", "PreToolUse", "PostToolUse": return .running
        case "PermissionRequest": return .waitingApproval
        default: return nil
        }
    }

    /// Outcome of applying a hook message — drives new-session flash and Done announce.
    struct ApplyResult {
        var isNew: Bool
        /// Set to the session's id when a top-level session transitioned running → idle
        /// via `Stop` (nil otherwise).
        var completedSessionID: String?
    }

    /// Apply a hook message. `completedSessionID` is set to the session's id when its prior
    /// status was `.running` and the event is `Stop`.
    @discardableResult
    func apply(_ msg: HookMessage) -> ApplyResult {
        let newStatus = Self.status(for: msg.event)
        let isNew: Bool
        let didCompleteTurn: Bool
        if let i = index[msg.sessionId] {
            let priorStatus = sessions[i].status
            let isTopLevel = sessions[i].parentId == nil
            // A pending approval or question owns the status: a late running event (parallel
            // tool, subagent traffic) must never clear the waiting card from under the user.
            let waitingPending = priorStatus == .waitingApproval
                && (pendingApprovals.contains { $0.sessionId == msg.sessionId }
                    || pendingQuestions.contains { $0.sessionId == msg.sessionId })
            if let newStatus, !waitingPending || newStatus == .waitingApproval {
                sessions[i].status = newStatus
                if newStatus == .running { sessions[i].hasRun = true }
            }
            if let tool = msg.toolName {
                sessions[i].lastTool = tool
                sessions[i].lastToolSummary = msg.toolSummary
            }
            if let terminal = msg.terminal { sessions[i].terminal = terminal }
            if let tty = msg.tty { sessions[i].tty = tty }
            if let prompt = msg.userPrompt { sessions[i].lastUserPrompt = prompt }
            sessions[i].lastActivity = .now
            isNew = false
            didCompleteTurn = msg.event == "Stop" && isTopLevel && priorStatus == .running
            // A top-level Stop means the turn is fully over — any subagent still hanging
            // around under it is orphaned (its own SubagentStop never arrived, e.g. it was
            // cancelled mid-flight) and would otherwise sit at `.running` forever, dragging
            // `worstStatus` and keeping the pill's "Working…" up with nothing left running.
            if msg.event == "Stop" && isTopLevel {
                let before = sessions.count
                sessions.removeAll { $0.parentId == msg.sessionId }
                if sessions.count != before { reindex() }
            }
        } else {
            index[msg.sessionId] = sessions.count
            var session = Session(id: msg.sessionId, source: msg.source,
                                  cwd: msg.cwd, status: newStatus ?? .idle,
                                  parentId: msg.parentId, agentType: msg.agentType)
            session.hasRun = (newStatus == .running)
            session.lastTool = msg.toolName
            session.lastToolSummary = msg.toolSummary
            session.terminal = msg.terminal
            session.tty = msg.tty
            session.lastUserPrompt = msg.userPrompt
            sessions.append(session)
            isNew = true
            didCompleteTurn = false
        }
        prune()
        schedulePersist()
        return ApplyResult(isNew: isNew, completedSessionID: didCompleteTurn ? msg.sessionId : nil)
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
        let idleCutoff = Date.now.addingTimeInterval(-15 * 60)
        let before = sessions.count
        sessions.removeAll { $0.status == .idle && $0.lastActivity < idleCutoff }
        // A `.running` row is otherwise never revisited once set — if its own Stop/SubagentStop/
        // SessionEnd never arrives (crashed process, killed session, an orphaned subagent, a
        // stray manual test), it sits at `.running` forever and keeps `worstStatus` (and the
        // pill's "Working…") stuck on with nothing actually running. Settle it back to idle
        // after a long, generous silence — real tool calls report far more often than this —
        // so it rejoins the normal idle lifecycle instead of lying about still being active.
        let runningStaleCutoff = Date.now.addingTimeInterval(-20 * 60)
        for i in sessions.indices
        where sessions[i].status == .running && sessions[i].lastActivity < runningStaleCutoff {
            sessions[i].status = .idle
        }
        if sessions.count > 15 {
            sessions = Array(sessions.sorted { $0.lastActivity > $1.lastActivity }.prefix(15))
        }
        if sessions.count != before { reindex() }
    }

    /// Marks a session as having done real work at least once, so a still-fresh `.idle` row
    /// (just started, no tool call yet) doesn't render as "Done".
    private func markRunning(_ i: Int) {
        sessions[i].status = .running
        sessions[i].hasRun = true
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
                markRunning(i)
            }
        }
    }

    /// Drop the pending approval for a session (on decision or timeout) and un-wait it.
    func removeApproval(sessionId: String) {
        pendingApprovals.removeAll { $0.sessionId == sessionId }
        if let i = index[sessionId], sessions[i].status == .waitingApproval {
            markRunning(i)
        }
    }

    /// Drop the pending question for a session (on answer or "Open in Claude") and un-wait it.
    func removeQuestion(sessionId: String) {
        pendingQuestions.removeAll { $0.sessionId == sessionId }
        if let i = index[sessionId], sessions[i].status == .waitingApproval {
            markRunning(i)
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
        case .idle: return .secondary
        }
    }

    var label: String {
        switch self {
        case .waitingApproval: return "needs approval"
        case .running: return "running"
        case .idle: return "idle"
        case .error: return "error"
        }
    }
}
