import Foundation
import AppKit
import AgentShelfCore

/// Thread-safe holder for the decision produced on the main actor and read back on the
/// blocking socket thread. @unchecked Sendable: access is serialized by the lock.
final class DecisionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Decision?
    func set(_ d: Decision) { lock.lock(); value = d; lock.unlock() }
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
    private let onDecide: (Decision) -> Void
    private(set) var resolved = false

    init(message: HookMessage, onDecide: @escaping (Decision) -> Void) {
        self.sessionId = message.sessionId
        self.source = message.source
        self.cwd = message.cwd
        self.toolName = message.toolName ?? "action"
        self.toolSummary = message.toolSummary ?? ""
        self.onDecide = onDecide
    }

    var folderName: String { (cwd as NSString).lastPathComponent }

    func decide(_ behavior: Decision.Behavior) {
        guard !resolved else { return }
        resolved = true
        onDecide(Decision(behavior))
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
