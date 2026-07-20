import Testing
import Foundation
@testable import AgentShelfCore

@Test func socketPathIsStable() {
    #expect(AgentShelf.socketPath == "/tmp/agentshelf.sock")
}

@Test func capabilityTiering() {
    #expect(AgentSource.claudeCode.capability == .fullApproval)
    #expect(AgentSource.codex.capability == .monitorOnly)
    #expect(AgentSource.geminiCLI.capability == .monitorOnly)
    #expect(AgentSource.cursor.capability == .monitorOnly)
}

@Test func folderNameFromCwd() {
    let s = Session(id: "1", source: .claudeCode, cwd: "/Users/ab/Desktop/AgentShelf",
                    status: .running)
    #expect(s.folderName == "AgentShelf")
}

@Test func permissionRequestRoundTrips() throws {
    let path = NSTemporaryDirectory() + "as-test-\(UUID().uuidString).sock"
    let server = UnixSocketServer(path: path)
    try server.start { msg in msg.needsDecision ? Decision(.deny) : nil }
    defer { server.stop() }

    let req = HookMessage(event: "PermissionRequest", source: .claudeCode,
                          sessionId: "s1", cwd: "/tmp", needsDecision: true)
    let decision = SocketClient.send(req, to: path, awaitDecisionTimeout: 5)
    #expect(decision?.behavior == .deny)
}

@Test func fireAndForgetGetsNoReply() throws {
    let path = NSTemporaryDirectory() + "as-test-\(UUID().uuidString).sock"
    let server = UnixSocketServer(path: path)
    try server.start { _ in nil }
    defer { server.stop() }

    let msg = HookMessage(event: "PreToolUse", source: .claudeCode,
                          sessionId: "s1", cwd: "/tmp", toolName: "Bash")
    let decision = SocketClient.send(msg, to: path, awaitDecisionTimeout: 0)
    #expect(decision == nil)
}

@Test func absentAppFailsOpen() {
    // No server listening -> connect fails -> nil (agent proceeds via its own prompt).
    let path = NSTemporaryDirectory() + "as-missing-\(UUID().uuidString).sock"
    let req = HookMessage(event: "PermissionRequest", source: .claudeCode,
                          sessionId: "s1", cwd: "/tmp", needsDecision: true)
    #expect(SocketClient.send(req, to: path, awaitDecisionTimeout: 1) == nil)
}
