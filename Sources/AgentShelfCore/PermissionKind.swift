import Foundation

/// How a PermissionRequest should be surfaced in the notch.
public enum PermissionKind: String, Codable, Sendable {
    case none        // not a permission event
    case binary      // a yes/no tool grant -> Allow/Deny card; the hook blocks for a decision
    case nonBinary   // a choice, not a grant -> non-blocking "needs input" notice; hook does NOT block
}

public enum PermissionClassifier {
    /// Tools whose prompt is a *choice among options*, not a yes/no grant. The hook reply is
    /// limited to allow/deny, so the notch can't represent these — it gets out of the way and
    /// lets Claude's own prompt drive. Tune against real payloads (see AGENTSHELF_DEBUG_PAYLOAD).
    public static let nonBinaryTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    public static func kind(event: String, toolName: String?) -> PermissionKind {
        guard event == "PermissionRequest" else { return .none }
        if let toolName, nonBinaryTools.contains(toolName) { return .nonBinary }
        return .binary
    }
}
