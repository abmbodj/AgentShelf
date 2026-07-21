import Foundation
import AgentShelfCore

// Thin CLI over the Core installers (logic lives in Core so the app's menu reuses it).
//   agentshelf-setup install|uninstall|status [--settings <path>]
//   agentshelf-setup statusline install|uninstall|status [--settings <path>]

func bundledHookURL() -> URL {
    (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
        .deletingLastPathComponent()
        .appendingPathComponent("agentshelf-hook")
}

let args = CommandLine.arguments

var settingsURL: URL? = nil
if let i = args.firstIndex(of: "--settings"), i + 1 < args.count {
    settingsURL = URL(fileURLWithPath: args[i + 1])
}

do {
    if args.count > 1, args[1] == "statusline" {
        let installer = StatusLineInstaller(settingsURL: settingsURL)
        switch args.count > 2 ? args[2] : "status" {
        case "install":
            try installer.install()
            print("Wrapped statusLine in \(installer.settingsURL.path)")
        case "uninstall":
            try installer.uninstall()
            print("Restored statusLine in \(installer.settingsURL.path)")
        case "status":
            print(try installer.isInstalled() ? "installed" : "not installed")
        default:
            print("usage: agentshelf-setup statusline install|uninstall|status [--settings <path>]")
            exit(2)
        }
    } else {
        // Same shape as the app's install: managed binary path, single-quoted.
        let installer = ClaudeInstaller(settingsURL: settingsURL,
                                        hookCommand: "'\(ManagedHookBinary.url.path)' claudeCode")
        switch args.count > 1 ? args[1] : "status" {
        case "install":
            try ManagedHookBinary.install(from: bundledHookURL())
            try installer.install()
            print("Installed agentshelf-hook into \(installer.settingsURL.path)")
        case "uninstall":
            try installer.uninstall()
            print("Removed agentshelf-hook from \(installer.settingsURL.path)")
        case "status":
            print(try installer.isInstalled() ? "installed" : "not installed")
        default:
            print("usage: agentshelf-setup [statusline] install|uninstall|status [--settings <path>]")
            exit(2)
        }
    }
} catch InstallerError.unparseable(let p) {
    FileHandle.standardError.write(Data("refusing: \(p) is not valid JSON; changed nothing\n".utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
