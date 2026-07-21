import Testing
import Foundation
@testable import AgentShelfCore

private func tempSettings(_ contents: String? = nil) -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("as-settings-\(UUID().uuidString).json")
    if let contents { try? contents.write(to: url, atomically: true, encoding: .utf8) }
    return url
}

private let hookCmd = "/opt/agentshelf-hook claudeCode"

// A realistic config: a statusLine and a user's own PreToolUse hook that MUST survive.
private let realisticConfig = """
{
  "statusLine" : { "type" : "command", "command" : "gsd-statusline" },
  "hooks" : {
    "PreToolUse" : [
      { "matcher" : "Bash", "hooks" : [ { "type" : "command", "command" : "my-foreign-hook" } ] }
    ]
  }
}
"""

@Test func installIsIdempotentAndDetectable() throws {
    let url = tempSettings("{}")
    let inst = ClaudeInstaller(settingsURL: url, hookCommand: hookCmd)
    try inst.install()
    try inst.install()   // second install must not duplicate entries
    #expect(try inst.isInstalled())

    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    let hooks = root["hooks"] as! [String: Any]
    let pre = hooks["PreToolUse"] as! [[String: Any]]
    #expect(pre.count == 1)   // exactly one group, not two
}

@Test func installPreservesForeignContent() throws {
    let url = tempSettings(realisticConfig)
    let inst = ClaudeInstaller(settingsURL: url, hookCommand: hookCmd)
    try inst.install()

    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    // statusLine untouched
    #expect((root["statusLine"] as? [String: Any])?["command"] as? String == "gsd-statusline")
    // foreign PreToolUse hook still present alongside ours
    let pre = (root["hooks"] as! [String: Any])["PreToolUse"] as! [[String: Any]]
    let commands = pre.flatMap { ($0["hooks"] as! [[String: Any]]).compactMap { $0["command"] as? String } }
    #expect(commands.contains("my-foreign-hook"))
    #expect(commands.contains(hookCmd))
}

@Test func uninstallIsByteExactWhenNothingElseChanged() throws {
    let url = tempSettings(realisticConfig)
    let original = try Data(contentsOf: url)
    let inst = ClaudeInstaller(settingsURL: url, hookCommand: hookCmd)

    try inst.install()
    #expect(try Data(contentsOf: url) != original)   // install did reformat/add
    try inst.uninstall()
    #expect(try Data(contentsOf: url) == original)    // uninstall restored byte-for-byte
    #expect(try !inst.isInstalled())
}

@Test func uninstallKeepsForeignHooks() throws {
    let url = tempSettings(realisticConfig)
    let inst = ClaudeInstaller(settingsURL: url, hookCommand: hookCmd)
    try inst.install()
    try inst.uninstall()

    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    let pre = (root["hooks"] as! [String: Any])["PreToolUse"] as! [[String: Any]]
    let commands = pre.flatMap { ($0["hooks"] as! [[String: Any]]).compactMap { $0["command"] as? String } }
    #expect(commands == ["my-foreign-hook"])
}

@Test func permissionRequestEntryCarriesLongTimeout() throws {
    let url = tempSettings("{}")
    try ClaudeInstaller(settingsURL: url, hookCommand: hookCmd).install()

    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    let hooks = root["hooks"] as! [String: Any]
    let perm = (hooks["PermissionRequest"] as! [[String: Any]])
        .flatMap { $0["hooks"] as! [[String: Any]] }
    // Without this Claude Code kills the hook at its default timeout and fails open.
    #expect(perm.first?["timeout"] as? Int == AgentShelf.hookEntryTimeout)
    // Other events stay timeout-free (they're fire-and-forget).
    let start = (hooks["SessionStart"] as! [[String: Any]]).flatMap { $0["hooks"] as! [[String: Any]] }
    #expect(start.first?["timeout"] == nil)
}

@Test func reinstallUpgradesStaleEntries() throws {
    // Simulate an old install: our marker with an outdated path and no timeout.
    let url = tempSettings("""
    { "hooks": { "PermissionRequest": [ { "matcher": "*", "hooks": [
        { "type": "command", "command": "/old/build/dir/agentshelf-hook claudeCode" }
    ] } ] } }
    """)
    let inst = ClaudeInstaller(settingsURL: url, hookCommand: hookCmd)
    #expect(try inst.isInstalled())   // old path still detected via the marker
    try inst.install()

    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    let perm = ((root["hooks"] as! [String: Any])["PermissionRequest"] as! [[String: Any]])
        .flatMap { $0["hooks"] as! [[String: Any]] }
    // Sanitize-then-append: exactly one entry, current command, timeout added.
    #expect(perm.count == 1)
    #expect(perm.first?["command"] as? String == hookCmd)
    #expect(perm.first?["timeout"] as? Int == AgentShelf.hookEntryTimeout)
}

@Test func refusesUnparseableConfig() throws {
    let url = tempSettings("{ this is not json")
    let before = try Data(contentsOf: url)
    let inst = ClaudeInstaller(settingsURL: url, hookCommand: hookCmd)

    #expect(throws: InstallerError.self) { try inst.install() }
    #expect(try Data(contentsOf: url) == before)   // changed nothing
}
