import Testing
import Foundation
@testable import AgentShelfCore

// MARK: - Registry

@Test func registryCoversAll26Sources() {
    #expect(AgentRegistry.all.count == 26)
    #expect(Set(AgentRegistry.all.map(\.source)) == Set(AgentSource.allCases))
}

@Test func onlyClaudeCodeIsFullApproval() {
    let fullApproval = AgentRegistry.all.filter { $0.tier == .fullApproval }.map(\.source)
    #expect(fullApproval == [.claudeCode])
    #expect(AgentSource.claudeCode.capability == .fullApproval)
    #expect(AgentSource.codex.capability == .monitorOnly)
}

// MARK: - Process matching (boundary, not substring)

@Test func matchesOnPathAndWordBoundaries() {
    #expect(ProcessMonitor.matches(command: "/usr/local/bin/claude --foo", token: "claude"))
    #expect(ProcessMonitor.matches(command: "node /x/opencode/bin.js", token: "opencode"))
    #expect(ProcessMonitor.matches(command: "/opt/homebrew/bin/amp", token: "amp"))
    #expect(ProcessMonitor.matches(command: "node /x/@sourcegraph/amp/index.js", token: "amp"))
}

@Test func doesNotMatchMidToken() {
    // "claude-code" is a different binary — must not fire the "claude" row.
    #expect(!ProcessMonitor.matches(command: "node /x/claude-code/cli.js", token: "claude"))
    #expect(!ProcessMonitor.matches(command: "grep example", token: "amp"))
    #expect(!ProcessMonitor.matches(command: "", token: "amp"))
}

@Test func parseMapsCommandsToSources() {
    let ps = """
      123 /usr/local/bin/claude chat
     4567 node /Users/x/opencode/bin.js run
     8901 grep something
    """
    let hits = ProcessMonitor.parse(psOutput: ps)
    #expect(hits.contains { $0.source == .claudeCode && $0.pid == 123 })
    #expect(hits.contains { $0.source == .openCode && $0.pid == 4567 })
    #expect(!hits.contains { $0.pid == 8901 })
}

// MARK: - Log tailing

@Test func lastRecordReadsFinalJsonlLine() {
    let text = """
    {"tool_name":"Read","file_path":"/a"}
    {"tool_name":"Edit","file_path":"/b/foo.ts"}
    """
    let rec = SessionLogTailer.lastRecord(text, ext: "jsonl")
    #expect(rec?["tool_name"] as? String == "Edit")
}

@Test func activityEnrichesFromCodexLog() throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agentshelf-test-\(UUID().uuidString)")
    let dir = tmp.appendingPathComponent(".codex/sessions")   // matches registry codex logSource
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    // Nested payload shape — exercises the one-level key probe.
    let line = #"{"message":{"tool_name":"Bash","command":"swift test"}}"#
    try Data(line.utf8).write(to: dir.appendingPathComponent("s.jsonl"))

    let act = SessionLogTailer.activity(for: .codex, home: tmp)
    #expect(act?.tool == "Bash")
    #expect(act?.summary == "swift test")
    #expect(act?.isFresh() == true)
}

@Test func activityIsNilForPresenceTierAgent() {
    #expect(SessionLogTailer.activity(for: .droid) == nil)   // no logSource -> no enrichment
}

@Test func activityIsFreshOnlyWithinWindow() throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agentshelf-test-\(UUID().uuidString)")
    let dir = tmp.appendingPathComponent(".codex/sessions")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let file = dir.appendingPathComponent("old.jsonl")
    try Data(#"{"tool_name":"Read","file_path":"/a"}"#.utf8).write(to: file)
    // Backdate mtime past the fresh window so a brand-new process wouldn't look "working".
    let staleDate = Date.now.addingTimeInterval(-(SessionLogTailer.freshWindow + 5))
    try FileManager.default.setAttributes([.modificationDate: staleDate], ofItemAtPath: file.path)

    let act = SessionLogTailer.activity(for: .codex, home: tmp)
    #expect(act?.tool == "Read")
    #expect(act?.isFresh() == false)
}

// MARK: - Monitor row status (process alive ≠ working)

@Test func newMonitorRowWithoutFreshActivityIsIdle() {
    let state = SessionLogTailer.rowState(isFresh: false)
    #expect(state.status == .idle)
    #expect(state.hasRun == false)
    #expect(state.applyToolLabels == false)
}

@Test func freshLogActivityPromotesMonitorRowToRunning() {
    let state = SessionLogTailer.rowState(isFresh: true)
    #expect(state.status == .running)
    #expect(state.hasRun == true)
    #expect(state.applyToolLabels == true)
}

@Test func staleLogAfterPriorWorkSettlesToIdleKeepingHasRun() {
    let state = SessionLogTailer.rowState(isFresh: false, priorHasRun: true)
    #expect(state.status == .idle)
    #expect(state.hasRun == true)
    #expect(state.applyToolLabels == false)
}
