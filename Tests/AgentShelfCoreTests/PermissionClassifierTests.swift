import Testing
@testable import AgentShelfCore

@Test func binaryToolPermissionsGetAllowDeny() {
    #expect(PermissionClassifier.kind(event: "PermissionRequest", toolName: "Bash") == .binary)
    #expect(PermissionClassifier.kind(event: "PermissionRequest", toolName: "Edit") == .binary)
    #expect(PermissionClassifier.kind(event: "PermissionRequest", toolName: "mcp__foo__bar") == .binary)
}

@Test func choiceToolsAreNonBinary() {
    #expect(PermissionClassifier.kind(event: "PermissionRequest", toolName: "AskUserQuestion") == .nonBinary)
    #expect(PermissionClassifier.kind(event: "PermissionRequest", toolName: "ExitPlanMode") == .nonBinary)
}

@Test func nonPermissionEventsAreNone() {
    #expect(PermissionClassifier.kind(event: "PreToolUse", toolName: "Bash") == .none)
    #expect(PermissionClassifier.kind(event: "SessionStart", toolName: nil) == .none)
}

@Test func needsDecisionOnlyForBinary() {
    let binary = HookMessage(event: "PermissionRequest", source: .claudeCode, sessionId: "s",
                             cwd: "/tmp", toolName: "Bash", permissionKind: .binary)
    let choice = HookMessage(event: "PermissionRequest", source: .claudeCode, sessionId: "s",
                             cwd: "/tmp", toolName: "AskUserQuestion", permissionKind: .nonBinary)
    #expect(binary.needsDecision)
    #expect(!choice.needsDecision)
}
