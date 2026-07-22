import Testing
import Foundation
@testable import AgentShelfCore

private func makeInstaller(_ contents: String?) -> CursorSettingsInstaller {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("as-cursor-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let settings = dir.appendingPathComponent("settings.json")
    if let contents { try? contents.write(to: settings, atomically: true, encoding: .utf8) }
    return CursorSettingsInstaller(settingsURL: settings, supportDir: dir.appendingPathComponent("support"))
}

private func root(of installer: CursorSettingsInstaller) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: installer.settingsURL)) as! [String: Any]
}

@Test func cursorSettingsAddsSequenceToDefaultDescription() throws {
    let inst = makeInstaller("{}")
    try inst.install()
    let value = try root(of: inst)["terminal.integrated.tabs.description"] as! String
    #expect(value.contains("${sequence}"))
    #expect(value.contains("${cwdFolder}"))   // default template preserved, not overwritten
    #expect(try inst.isInstalled())
}

@Test func cursorSettingsExtendsCustomDescriptionRatherThanOverwriting() throws {
    let inst = makeInstaller(#"{"terminal.integrated.tabs.description": "${cwd}", "foreign.setting": true}"#)
    try inst.install()
    let root = try root(of: inst)
    let value = root["terminal.integrated.tabs.description"] as! String
    #expect(value.hasPrefix("${cwd}"))
    #expect(value.contains("${sequence}"))
    #expect(root["foreign.setting"] as? Bool == true)   // untouched
}

@Test func cursorSettingsInstallIsIdempotent() throws {
    let inst = makeInstaller(#"{"terminal.integrated.tabs.description": "${sequence}"}"#)
    try inst.install()   // already contains ${sequence} -> no-op
    let value = try root(of: inst)["terminal.integrated.tabs.description"] as! String
    #expect(value == "${sequence}")
}

@Test func cursorSettingsUninstallRestoresOriginalValue() throws {
    let inst = makeInstaller(#"{"terminal.integrated.tabs.description": "${cwd}"}"#)
    try inst.install()
    try inst.uninstall()
    let value = try root(of: inst)["terminal.integrated.tabs.description"] as! String
    #expect(value == "${cwd}")
    #expect(try !inst.isInstalled())
    #expect(!FileManager.default.fileExists(atPath: inst.originalURL.path))
}

@Test func cursorSettingsUninstallRemovesKeyWhenNeverSet() throws {
    let inst = makeInstaller("{}")
    try inst.install()
    try inst.uninstall()
    #expect(try root(of: inst)["terminal.integrated.tabs.description"] == nil)
}

@Test func cursorSettingsRefusesUnparseableConfig() throws {
    let inst = makeInstaller("{ nope")
    let before = try Data(contentsOf: inst.settingsURL)
    #expect(throws: InstallerError.self) { try inst.install() }
    #expect(try Data(contentsOf: inst.settingsURL) == before)
}
