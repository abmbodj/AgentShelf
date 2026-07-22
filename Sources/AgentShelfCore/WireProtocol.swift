import Foundation

/// One AskUserQuestion option — mirrors Claude Code's tool_input.questions[].options[] shape
/// (verified against a real PermissionRequest payload, Claude Code 2.1.216).
public struct QuestionOption: Codable, Sendable, Equatable {
    public var label: String
    public var description: String
    public init(label: String, description: String) {
        self.label = label
        self.description = description
    }
}

/// One AskUserQuestion question — mirrors tool_input.questions[] (verified against a real
/// PermissionRequest payload). AskUserQuestion can carry 1-4 of these; only a single
/// non-multiSelect question is answerable inline (see QuestionRequest in the app).
public struct Question: Codable, Sendable, Equatable {
    public var question: String
    public var header: String
    public var options: [QuestionOption]
    public var multiSelect: Bool
    public init(question: String, header: String, options: [QuestionOption], multiSelect: Bool) {
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }
}

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
    public var parentId: String?      // parent session id — set only when this is a subagent
    public var agentType: String?     // subagent label, e.g. "explore" / "code-reviewer"
    public var questions: [Question]? // AskUserQuestion's tool_input.questions
    public var diffOld: String?       // Edit/MultiEdit old_string, or Write's prior file content
    public var diffNew: String?       // Edit/MultiEdit new_string, or Write's content
    public var userPrompt: String?    // UserPromptSubmit's prompt text
    public var terminal: String?      // TERM_PROGRAM from the hook's environment
    public var tty: String?           // controlling terminal device path (see ControllingTTY)

    public init(event: String, source: AgentSource, sessionId: String, cwd: String,
                toolName: String? = nil, toolSummary: String? = nil,
                permissionKind: PermissionKind = .none,
                parentId: String? = nil, agentType: String? = nil,
                questions: [Question]? = nil, diffOld: String? = nil, diffNew: String? = nil,
                userPrompt: String? = nil, terminal: String? = nil, tty: String? = nil) {
        self.event = event
        self.source = source
        self.sessionId = sessionId
        self.cwd = cwd
        self.toolName = toolName
        self.toolSummary = toolSummary
        self.permissionKind = permissionKind
        self.parentId = parentId
        self.agentType = agentType
        self.questions = questions
        self.diffOld = diffOld
        self.diffNew = diffNew
        self.userPrompt = userPrompt
        self.terminal = terminal
        self.tty = tty
    }

    /// The hook blocks for a decision only on a binary permission.
    public var needsDecision: Bool { permissionKind == .binary }
}

/// The app's reply for a PermissionRequest. Mirrors Claude Code's decision behavior.
/// `allowAlways` = allow now AND add a session-scoped rule so this tool stops asking.
public struct Decision: Codable, Sendable {
    public enum Behavior: String, Codable, Sendable { case allow, deny, allowAlways }
    public var behavior: Behavior
    public init(_ behavior: Behavior) { self.behavior = behavior }

    /// The decision object Claude Code expects inside the PermissionRequest reply.
    /// allowAlways carries an addRules permission update (tool-level, session-scoped —
    /// the safest "always" there is; nothing is written to any settings file).
    public func claudeDecision(toolName: String?) -> [String: Any] {
        switch behavior {
        case .allow: return ["behavior": "allow"]
        case .deny: return ["behavior": "deny"]
        case .allowAlways:
            guard let toolName else { return ["behavior": "allow"] }
            return [
                "behavior": "allow",
                "updatedPermissions": [[
                    "type": "addRules",
                    "rules": [["toolName": toolName]],
                    "behavior": "allow",
                    "destination": "session",
                ]],
            ]
        }
    }
}
