import Testing
import Foundation
@testable import AgentShelfCore

// Mirrors the user's real config: a GSD statusline (with embedded quotes) that MUST
// render unchanged while installed and come back byte-for-byte on uninstall.
private let realisticConfig = """
{
  "statusLine" : { "type" : "command", "command" : "node \\"/Users/x/.claude/hooks/gsd-statusline.js\\"" },
  "hooks" : { "PreToolUse" : [ { "matcher" : "*", "hooks" : [ { "type" : "command", "command" : "foreign" } ] } ] }
}
"""

private func makeInstaller(_ contents: String?) -> StatusLineInstaller {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("as-sl-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let settings = dir.appendingPathComponent("settings.json")
    if let contents { try? contents.write(to: settings, atomically: true, encoding: .utf8) }
    return StatusLineInstaller(settingsURL: settings, supportDir: dir.appendingPathComponent("support"))
}

private func root(of installer: StatusLineInstaller) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: installer.settingsURL)) as! [String: Any]
}

@Test func wrapsExistingStatusLine() throws {
    let inst = makeInstaller(realisticConfig)
    try inst.install()

    let statusLine = try root(of: inst)["statusLine"] as! [String: Any]
    // Command swapped to the (quoted) wrapper; type preserved.
    #expect(statusLine["command"] as? String == "'\(inst.wrapperURL.path)'")
    #expect(statusLine["type"] as? String == "command")
    #expect(try inst.isInstalled())

    // The wrapper delegates to the ORIGINAL command verbatim (embedded quotes intact)
    // and tees to the cache path.
    let script = try String(contentsOf: inst.wrapperURL, encoding: .utf8)
    #expect(script.contains(#"node "/Users/x/.claude/hooks/gsd-statusline.js""#))
    #expect(script.contains(inst.cacheURL.path))
    #expect(FileManager.default.isExecutableFile(atPath: inst.wrapperURL.path))
}

@Test func installIsIdempotentNeverWrapsItself() throws {
    let inst = makeInstaller(realisticConfig)
    try inst.install()
    try inst.install()   // second install must not wrap the wrapper

    let script = try String(contentsOf: inst.wrapperURL, encoding: .utf8)
    #expect(script.contains("gsd-statusline"))                       // still the original
    #expect(!script.contains("'\(inst.wrapperURL.path)'"))           // not itself
}

@Test func uninstallIsByteExact() throws {
    let inst = makeInstaller(realisticConfig)
    let original = try Data(contentsOf: inst.settingsURL)
    try inst.install()
    #expect(try Data(contentsOf: inst.settingsURL) != original)
    try inst.uninstall()
    #expect(try Data(contentsOf: inst.settingsURL) == original)
    #expect(try !inst.isInstalled())
    // All managed artifacts cleaned up.
    #expect(!FileManager.default.fileExists(atPath: inst.wrapperURL.path))
    #expect(!FileManager.default.fileExists(atPath: inst.cacheURL.path))
}

@Test func installWithoutExistingStatusLine() throws {
    let inst = makeInstaller("{}")
    try inst.install()
    #expect(try inst.isInstalled())
    // Fallback delegate prints a minimal model line rather than leaving a blank bar.
    let script = try String(contentsOf: inst.wrapperURL, encoding: .utf8)
    #expect(script.contains("python3"))

    try inst.uninstall()
    #expect(try root(of: inst)["statusLine"] == nil)   // key removed, not left empty
}

@Test func statusLineRefusesUnparseableConfig() throws {
    let inst = makeInstaller("{ nope")
    let before = try Data(contentsOf: inst.settingsURL)
    #expect(throws: InstallerError.self) { try inst.install() }
    #expect(try Data(contentsOf: inst.settingsURL) == before)
}

@Test func usageWindowsParse() throws {
    let payload = """
    {"model":{"display_name":"Opus"},"rate_limits":{
       "five_hour":{"used_percentage":42.4,"resets_at":"2026-07-21T20:00:00Z"},
       "seven_day":{"utilization":0.18}}}
    """
    let windows = ClaudeUsage.windows(from: Data(payload.utf8))
    #expect(windows == [UsageWindow(label: "5h", usedPercent: 42),
                        UsageWindow(label: "7d", usedPercent: 18)])
}

@Test func usageWindowsTolerateGarbage() {
    #expect(ClaudeUsage.windows(from: Data("not json".utf8)) == [])
    #expect(ClaudeUsage.windows(from: Data("{}".utf8)) == [])
    #expect(ClaudeUsage.windows(from: Data(#"{"rate_limits":{"five_hour":"nope"}}"#.utf8)) == [])
}
