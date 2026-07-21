import Foundation

/// Normalized message the hook CLI sends to the app over the socket (one JSON line).
/// The hook extracts the few fields we need from the agent's raw hook payload so
/// Core never has to know each agent's payload shape.
public struct HookMessage: Codable, Sendable {
    public var event: String          // "SessionStart" | "PreToolUse" | "PermissionRequest" | "Stop" | ...
    public var source: AgentSource
    public var sessionId: String
    public var cwd: String
    public var toolName: String?      // for PreToolUse / PermissionRequest
    public var toolSummary: String?   // human-readable action, for the approval panel
    public var permissionKind: PermissionKind   // .binary / .nonBinary / .none

    public init(event: String, source: AgentSource, sessionId: String, cwd: String,
                toolName: String? = nil, toolSummary: String? = nil,
                permissionKind: PermissionKind = .none) {
        self.event = event
        self.source = source
        self.sessionId = sessionId
        self.cwd = cwd
        self.toolName = toolName
        self.toolSummary = toolSummary
        self.permissionKind = permissionKind
    }

    /// The hook blocks for a decision only on a binary permission.
    public var needsDecision: Bool { permissionKind == .binary }
}

/// The app's reply for a PermissionRequest. Mirrors Claude Code's decision behavior.
public struct Decision: Codable, Sendable {
    public enum Behavior: String, Codable, Sendable { case allow, deny }
    public var behavior: Behavior
    public init(_ behavior: Behavior) { self.behavior = behavior }
}
