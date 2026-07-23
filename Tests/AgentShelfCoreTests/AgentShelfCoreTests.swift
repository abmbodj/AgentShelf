import Testing
import Foundation
@testable import AgentShelfCore

@Test func socketPathIsStable() {
    // In App Support (periodic /tmp cleanup would delete a long-lived socket).
    #expect(AgentShelf.socketPath.hasSuffix("Library/Application Support/AgentShelf/agentshelf.sock"))
    #expect(!AgentShelf.socketPath.hasPrefix("/tmp"))
}

@Test func approvalDeadlineChainIsOrdered() {
    // Each stage must resolve before the outer one kills it (all expiries fail open).
    #expect(Double(AgentShelf.hookEntryTimeout) > AgentShelf.hookDecisionTimeout)
    #expect(AgentShelf.hookDecisionTimeout > AgentShelf.appDecisionTimeout)
}

@Test func claudeDecisionShapes() throws {
    #expect(Decision(.allow).claudeDecision(toolName: "Bash") as? [String: String] == ["behavior": "allow"])
    #expect(Decision(.deny).claudeDecision(toolName: "Bash") as? [String: String] == ["behavior": "deny"])

    let always = Decision(.allowAlways).claudeDecision(toolName: "Bash")
    #expect(always["behavior"] as? String == "allow")
    let updates = try #require(always["updatedPermissions"] as? [[String: Any]])
    #expect(updates.count == 1)
    #expect(updates[0]["type"] as? String == "addRules")
    #expect(updates[0]["behavior"] as? String == "allow")
    #expect(updates[0]["destination"] as? String == "session")
    #expect(updates[0]["rules"] as? [[String: String]] == [["toolName": "Bash"]])

    // No tool name to build a rule from -> degrade to a plain allow.
    #expect(Decision(.allowAlways).claudeDecision(toolName: nil) as? [String: String] == ["behavior": "allow"])
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

@Test func hasRunDefaultsFalseAndRoundTrips() throws {
    // A freshly constructed session hasn't run yet (SessionStore only flips this once
    // status reaches .running) — the notch label logic depends on this starting false.
    var s = Session(id: "1", source: .claudeCode, cwd: "/tmp", status: .idle)
    #expect(s.hasRun == false)

    s.hasRun = true
    let data = try JSONEncoder().encode(s)
    let decoded = try JSONDecoder().decode(Session.self, from: data)
    #expect(decoded.hasRun == true)

    // Sessions persisted before this field existed must still decode (missing key -> default).
    var legacyObj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    legacyObj.removeValue(forKey: "hasRun")
    let legacyData = try JSONSerialization.data(withJSONObject: legacyObj)
    let legacy = try JSONDecoder().decode(Session.self, from: legacyData)
    #expect(legacy.hasRun == false)
}

@Test func permissionRequestRoundTrips() throws {
    let path = NSTemporaryDirectory() + "as-test-\(UUID().uuidString).sock"
    let server = UnixSocketServer(path: path)
    try server.start { msg in msg.needsDecision ? Decision(.deny) : nil }
    defer { server.stop() }

    let req = HookMessage(event: "PermissionRequest", source: .claudeCode,
                          sessionId: "s1", cwd: "/tmp", permissionKind: .binary)
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
                          sessionId: "s1", cwd: "/tmp", permissionKind: .binary)
    #expect(SocketClient.send(req, to: path, awaitDecisionTimeout: 1) == nil)
}
