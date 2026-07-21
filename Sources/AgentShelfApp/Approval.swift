import Foundation
import AppKit
import AgentShelfCore

/// Thread-safe holder for the decision produced on the main actor and read back on the
/// blocking socket thread. @unchecked Sendable: access is serialized by the lock.
final class DecisionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Decision?
    func set(_ d: Decision?) { lock.lock(); value = d; lock.unlock() }
    func get() -> Decision? { lock.lock(); defer { lock.unlock() }; return value }
}

/// A pending permission request shown in the notch. `decide` resolves it exactly once.
@MainActor
final class ApprovalRequest: Identifiable {
    let id = UUID()
    let sessionId: String
    let source: AgentSource
    let cwd: String
    let toolName: String
    let toolSummary: String
    let diff: [DiffLine]   // empty unless the tool is Edit/MultiEdit/Write
    private let onDecide: (Decision?) -> Void
    private(set) var resolved = false

    init(message: HookMessage, onDecide: @escaping (Decision?) -> Void) {
        self.sessionId = message.sessionId
        self.source = message.source
        self.cwd = message.cwd
        self.toolName = message.toolName ?? "action"
        self.toolSummary = message.toolSummary ?? ""
        if let old = message.diffOld, let new = message.diffNew {
            self.diff = LineDiff.lines(old: old, new: new)
        } else {
            self.diff = []
        }
        self.onDecide = onDecide
    }

    var folderName: String { (cwd as NSString).lastPathComponent }

    func decide(_ behavior: Decision.Behavior) {
        guard !resolved else { return }
        resolved = true
        onDecide(Decision(behavior))
    }

    /// Hand the prompt back to Claude's own UI: resolve with no reply, so the hook
    /// prints nothing and Claude re-prompts natively (used by "Open in Claude").
    func pass() {
        guard !resolved else { return }
        resolved = true
        onDecide(nil)
    }
}

/// An answerable AskUserQuestion (single question, single select). Hooks can't supply a
/// tool's result — only allow/deny/modify-input — so this can't be answered over the socket
/// like a binary permission. Instead `choose` injects the option's ordinal keypress into the
/// terminal that owns this session (see TerminalInjector); Claude Code's menu accepts a bare
/// digit with no Enter needed. Multi-question / multi-select prompts fall back to
/// AttentionNotice below — driving multi-step CLI navigation by injection is too brittle.
@MainActor
final class QuestionRequest: Identifiable {
    let id = UUID()
    let sessionId: String
    let source: AgentSource
    let cwd: String
    let terminal: String?
    let question: String
    let options: [QuestionOption]
    private(set) var resolved = false
    private let onResolve: () -> Void

    /// nil if the message isn't a single-question, single-select AskUserQuestion.
    init?(message: HookMessage, onResolve: @escaping () -> Void) {
        guard let qs = message.questions, qs.count == 1,
              let q = qs.first, !q.multiSelect, !q.options.isEmpty else { return nil }
        self.sessionId = message.sessionId
        self.source = message.source
        self.cwd = message.cwd
        self.terminal = message.terminal
        self.question = q.question
        self.options = q.options
        self.onResolve = onResolve
    }

    var folderName: String { (cwd as NSString).lastPathComponent }

    /// Injects the option's 1-based ordinal into the bound terminal. Runs off the main thread:
    /// TerminalInjector shells out to osascript, which can block for seconds — or indefinitely —
    /// on a one-time "Allow AgentShelf to control System Events" permission prompt, and that
    /// must never freeze the notch's UI (it did, before this was made async). `onInjectFailed`
    /// fires on the main actor if no matching terminal window was found, so the caller can fall
    /// back to "Open in Claude" instead of leaving the question stuck with no way to answer it.
    func choose(_ index: Int, onInjectFailed: @escaping @Sendable () -> Void) {
        guard !resolved else { return }
        let cwd = cwd, terminal = terminal
        let keys = String(index + 1)
        Task.detached {
            let ok = TerminalInjector.inject(keys: keys, cwd: cwd, terminal: terminal)
            await MainActor.run { [weak self] in
                guard let self, !self.resolved else { return }
                if ok { self.resolved = true; self.onResolve() } else { onInjectFailed() }
            }
        }
    }

    /// "Open in Claude": give up on answering inline, just dismiss the card.
    func dismiss() {
        guard !resolved else { return }
        resolved = true
        onResolve()
    }
}

/// A non-binary permission (a choice, not a grant): the notch can't decide it, so this is a
/// non-blocking notice that just points the user to Claude's own prompt. No decision closure.
@MainActor
final class AttentionNotice: Identifiable {
    let id = UUID()
    let sessionId: String
    let source: AgentSource
    let cwd: String
    let toolName: String

    init(message: HookMessage) {
        self.sessionId = message.sessionId
        self.source = message.source
        self.cwd = message.cwd
        self.toolName = message.toolName ?? "input"
    }

    var folderName: String { (cwd as NSString).lastPathComponent }
}

/// Approval sound, gated on the user's mute/sound preferences (set in the settings window).
enum ApprovalSound {
    static func play() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "agentshelf.muted") else { return }
        let name = defaults.string(forKey: "agentshelf.sound") ?? "Bottle"
        NSSound(named: name)?.play()
    }
}
