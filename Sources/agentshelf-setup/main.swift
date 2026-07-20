import Foundation
import AgentShelfCore

// Thin CLI over ClaudeInstaller (logic lives in Core so the app's settings UI reuses it).
//   agentshelf-setup install|uninstall|status [--settings <path>]

func hookPath() -> String {
    let dir = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
        .deletingLastPathComponent()
    return dir.appendingPathComponent("agentshelf-hook").path
}

let args = CommandLine.arguments
let command = args.count > 1 ? args[1] : "status"

var settingsURL: URL? = nil
if let i = args.firstIndex(of: "--settings"), i + 1 < args.count {
    settingsURL = URL(fileURLWithPath: args[i + 1])
}

let installer = ClaudeInstaller(settingsURL: settingsURL,
                                hookCommand: "\(hookPath()) claudeCode")

do {
    switch command {
    case "install":
        try installer.install()
        print("Installed agentshelf-hook into \(installer.settingsURL.path)")
    case "uninstall":
        try installer.uninstall()
        print("Removed agentshelf-hook from \(installer.settingsURL.path)")
    case "status":
        print(try installer.isInstalled() ? "installed" : "not installed")
    default:
        print("usage: agentshelf-setup install|uninstall|status [--settings <path>]")
        exit(2)
    }
} catch InstallerError.unparseable(let p) {
    FileHandle.standardError.write(Data("refusing: \(p) is not valid JSON; changed nothing\n".utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
