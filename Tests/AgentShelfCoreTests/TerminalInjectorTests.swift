import Testing
import Foundation
@testable import AgentShelfCore

/// TerminalInjector drives real GUI automation (Terminal.app + System Events), so it can't
/// run as part of the normal suite. Gate it behind AGENTSHELF_DEBUG_INJECTOR_TEST, same
/// pattern as the other AGENTSHELF_DEBUG_* manual knobs in this codebase, and run it by hand:
///   AGENTSHELF_DEBUG_INJECTOR_TEST=1 swift test --filter appleTerminalInjectionFindsTabByCwd
@Test(.enabled(if: ProcessInfo.processInfo.environment["AGENTSHELF_DEBUG_INJECTOR_TEST"] != nil))
func appleTerminalInjectionFindsTabByCwd() throws {
    let dir = "/tmp/agentshelf-injector-test-\(UUID().uuidString.prefix(8))"
    let outFile = "\(dir)/out.txt"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }

    // `read -k 1` (zsh) reads exactly one keystroke with no Enter required — the same shape
    // as Claude Code's raw-mode AskUserQuestion menu, without needing a live claude session
    // for the test. NOTE: zsh's `-n` (unlike bash's) still waits for a newline — `-k` is the
    // no-newline-required flag; using `-n` here would make this test hang forever.
    let osa = Process()
    osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    osa.arguments = ["-e", """
        tell application "Terminal"
            activate
            set w to do script "cd \(dir) && read -k 1 key; echo GOT:$key > out.txt"
            return id of window 1
        end tell
        """]
    let outPipe = Pipe()
    osa.standardOutput = outPipe
    try osa.run()
    osa.waitUntilExit()
    #expect(osa.terminationStatus == 0)
    let windowId = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    defer {
        if let windowId {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "tell application \"Terminal\" to close window id \(windowId)"]
            try? p.run(); p.waitUntilExit()
        }
    }

    // Give the shell a moment to start and cd before we go hunting for it by cwd.
    Thread.sleep(forTimeInterval: 3)

    let injected = TerminalInjector.inject(keys: "7", cwd: dir, terminal: "Apple_Terminal")
    #expect(injected)

    Thread.sleep(forTimeInterval: 0.5)
    let result = try? String(contentsOfFile: outFile, encoding: .utf8)
    #expect(result?.trimmingCharacters(in: .whitespacesAndNewlines) == "GOT:7")
}
