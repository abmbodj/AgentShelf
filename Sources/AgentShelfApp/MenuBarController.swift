import AppKit
import ServiceManagement
import AgentShelfCore

/// Menu-bar status item = the app's settings surface (simple toggles don't warrant a
/// window). Install/uninstall hooks, mute, sound, launch-at-login, quit.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let installer: ClaudeInstaller
    private let statusLineInstaller = StatusLineInstaller()
    private let cursorSettingsInstaller = CursorSettingsInstaller()
    private var availableUpdateURL: URL?

    override init() {
        // The registered command points at the MANAGED copy (stable path, survives app
        // rebuilds/moves). Single-quoted: the path contains "Application Support".
        installer = ClaudeInstaller(hookCommand: "'\(ManagedHookBinary.url.path)' claudeCode")
        super.init()
    }

    /// The hook binary shipped next to the app executable — the copy source.
    static func bundledHookURL() -> URL {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .deletingLastPathComponent()
            .appendingPathComponent("agentshelf-hook")
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.statusItemIcon()
        let menu = NSMenu()
        menu.delegate = self          // rebuild each time it opens (reflects live install state)
        item.menu = menu
        statusItem = item
        Task { await checkForUpdate() }
        reenableLaunchAtLoginUnlessUserDisabled()
    }

    /// The logo, bundled as a template image so AppKit renders it correctly across light/dark
    /// menu bars and the click-highlight state — same auto-adapting behavior the "cpu" SF Symbol
    /// had. Falls back to that symbol when unbundled (e.g. plain `swift run`, no Contents/Resources).
    private static func statusItemIcon() -> NSImage? {
        if let image = DesignTokens.agentLogo() {
            image.isTemplate = true
            image.size = NSSize(width: 20, height: 20)
            image.accessibilityDescription = "Agent Shelf"
            return image
        }
        return NSImage(systemSymbolName: "cpu", accessibilityDescription: "Agent Shelf")
    }

    /// Every launch: re-assert Launch at Login if it's not enabled, since rebuilds can change the
    /// app's code-signing identity and macOS/BTM silently drops the previous registration. Skipped
    /// only if the user explicitly turned it off themselves via the menu toggle.
    private func reenableLaunchAtLoginUnlessUserDisabled() {
        guard SMAppService.mainApp.status != .enabled else { return }
        guard !UserDefaults.standard.bool(forKey: Self.userDisabledLaunchAtLoginKey) else { return }
        try? SMAppService.mainApp.register()
    }

    /// Once per launch: if GitHub has a newer release than this build, surface a menu item
    /// linking to it. No auto-download — just a nudge.
    private func checkForUpdate() async {
        guard let release = await UpdateChecker.fetchLatest() else { return }
        let current = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
        guard UpdateChecker.isNewer(release.tag, than: current) else { return }
        availableUpdateURL = release.htmlURL   // picked up next time the menu opens (rebuilds live)
    }

    /// Keep our hook entries current for users who already opted in — refreshes the
    /// managed binary copy and upgrades our settings entries (new events, timeout,
    /// managed path) across app updates. Idempotent, surgical, never touches entries
    /// we didn't add.
    func reconcileHooksIfInstalled() {
        guard (try? installer.isInstalled()) == true else { return }
        _ = try? ManagedHookBinary.install(from: Self.bundledHookURL())
        try? installer.install()
    }

    // Rebuild on open so the hook item and checkmarks always reflect current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let installed = (try? installer.isInstalled()) ?? false

        let header = NSMenuItem(title: "Agent Shelf", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if availableUpdateURL != nil {
            add(menu, "Update available →", #selector(openUpdate))
        }

        menu.addItem(.separator())

        add(menu, installed ? "Uninstall Claude Code Hooks" : "Install Claude Code Hooks",
            #selector(toggleHooks))

        let statusLineInstalled = (try? statusLineInstaller.isInstalled()) ?? false
        add(menu, statusLineInstalled ? "Uninstall Usage Statusline" : "Install Usage Statusline",
            #selector(toggleStatusLine))

        // Lets "Open in Claude" select the exact terminal tab a session is running in
        // (see CursorTabFocuser) instead of just activating Cursor. No-op if Cursor isn't
        // installed / the user doesn't run Claude Code inside Cursor's own terminal.
        let cursorTabsInstalled = (try? cursorSettingsInstaller.isInstalled()) ?? false
        add(menu, cursorTabsInstalled ? "Uninstall Cursor Tab Targeting" : "Install Cursor Tab Targeting",
            #selector(toggleCursorTabTargeting))

        add(menu, "Configure Agents…", #selector(configureAgents))
        add(menu, "Check Hooks…", #selector(checkHooks))

        let launch = add(menu, "Launch at Login", #selector(toggleLaunchAtLogin))
        launch.state = (SMAppService.mainApp.status == .enabled) ? .on : .off

        let mute = add(menu, "Mute Sounds", #selector(toggleMute))
        mute.state = UserDefaults.standard.bool(forKey: "agentshelf.muted") ? .on : .off

        let soundItem = NSMenuItem(title: "Sound", action: nil, keyEquivalent: "")
        let soundMenu = NSMenu()
        let current = UserDefaults.standard.string(forKey: "agentshelf.sound") ?? "Bottle"
        for name in ["Bottle", "Glass", "Ping", "Funk", "Hero", "Submarine"] {
            let i = NSMenuItem(title: name, action: #selector(setSound(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = name
            i.state = (name == current) ? .on : .off
            soundMenu.addItem(i)
        }
        soundItem.submenu = soundMenu
        menu.addItem(soundItem)

        menu.addItem(.separator())
        add(menu, "Quit Agent Shelf", #selector(quit)).keyEquivalent = "q"
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func toggleHooks() {
        do {
            if (try? installer.isInstalled()) == true {
                try installer.uninstall()
            } else {
                try ManagedHookBinary.install(from: Self.bundledHookURL())
                try installer.install()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Hook update failed"
            alert.informativeText = "\(error)"
            alert.runModal()
        }
    }

    @objc private func toggleStatusLine() {
        do {
            if (try? statusLineInstaller.isInstalled()) == true { try statusLineInstaller.uninstall() }
            else { try statusLineInstaller.install() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Statusline update failed"
            alert.informativeText = "\(error)"
            alert.runModal()
        }
    }

    @objc private func toggleCursorTabTargeting() {
        do {
            if (try? cursorSettingsInstaller.isInstalled()) == true { try cursorSettingsInstaller.uninstall() }
            else { try cursorSettingsInstaller.install() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Cursor settings update failed"
            alert.informativeText = "\(error)"
            alert.runModal()
        }
    }

    /// Zero-config surface: shows which of the 26 agents are running right now (auto-detected,
    /// no setup) and the one agent that needs a consented config edit — Claude Code's hook, for
    /// the full approve/deny flow. One click installs it; monitor-tier agents need nothing.
    @objc private func configureAgents() {
        let running = ProcessMonitor.scan()
        let names = Set(running.map { $0.source.displayName }).sorted()

        var lines = ["AgentShelf detects 26 agents automatically — no config for monitoring."]
        lines.append("")
        lines.append(names.isEmpty ? "No agents running right now."
                     : "Running now: \(names.joined(separator: ", "))")

        let hooksInstalled = (try? installer.isInstalled()) ?? false
        lines.append("")
        lines.append(hooksInstalled
                     ? "Claude Code hooks: installed (approve/deny in the notch is on)."
                     : "Claude Code hooks: not installed — install for approve/deny in the notch.")

        let alert = NSAlert()
        alert.messageText = "Agents"
        alert.informativeText = lines.joined(separator: "\n")
        if !hooksInstalled {
            alert.addButton(withTitle: "Install Claude Code Hooks")
            alert.addButton(withTitle: "Close")
            if alert.runModal() == .alertFirstButtonReturn { toggleHooks() }
        } else {
            alert.runModal()
        }
    }

    /// Quick health report: settings parse state, install state, managed binary, socket.
    /// "Repair" = refresh the managed binary + reinstall our entries (surgical as ever).
    @objc private func checkHooks() {
        var lines: [String] = []
        var healthy = true
        do {
            lines.append(try installer.isInstalled() ? "Hooks: installed" : "Hooks: not installed")
        } catch {
            lines.append("Settings: UNPARSEABLE — fix ~/.claude/settings.json by hand")
            healthy = false
        }
        let binPath = ManagedHookBinary.url.path
        if FileManager.default.isExecutableFile(atPath: binPath) {
            lines.append("Hook binary: OK")
        } else {
            lines.append("Hook binary: MISSING (\(binPath))")
            healthy = false
        }
        lines.append(FileManager.default.fileExists(atPath: AgentShelf.socketPath)
                     ? "Socket: present" : "Socket: MISSING (server failed to start?)")

        let alert = NSAlert()
        alert.messageText = healthy ? "Hooks look healthy" : "Hooks need repair"
        alert.informativeText = lines.joined(separator: "\n")
        if !healthy {
            alert.addButton(withTitle: "Repair")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                _ = try? ManagedHookBinary.install(from: Self.bundledHookURL())
                try? installer.install()
            }
        } else {
            alert.runModal()
        }
    }

    private static let userDisabledLaunchAtLoginKey = "agentshelf.userDisabledLaunchAtLogin"

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                UserDefaults.standard.set(true, forKey: Self.userDisabledLaunchAtLoginKey)
            } else {
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(false, forKey: Self.userDisabledLaunchAtLoginKey)
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = "\(error)\n\nThis needs the bundled AgentShelf.app (built via scripts/build-app.sh)."
            alert.runModal()
        }
    }

    @objc private func toggleMute() {
        let d = UserDefaults.standard
        d.set(!d.bool(forKey: "agentshelf.muted"), forKey: "agentshelf.muted")
    }

    @objc private func setSound(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        UserDefaults.standard.set(name, forKey: "agentshelf.sound")
        NSSound(named: name)?.play()   // preview
    }

    @objc private func openUpdate() {
        if let availableUpdateURL { NSWorkspace.shared.open(availableUpdateURL) }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
