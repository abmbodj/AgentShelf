import AppKit
import AgentShelfCore

/// Menu-bar status item = the app's settings surface (simple toggles don't warrant a
/// window). Install/uninstall hooks, mute, sound, quit.
/// ponytail: launch-at-login needs a real .app bundle (SMAppService) — add in Phase 4 packaging.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let installer: ClaudeInstaller

    override init() {
        installer = ClaudeInstaller(hookCommand: "\(Self.hookPath()) claudeCode")
        super.init()
    }

    static func hookPath() -> String {
        let dir = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .deletingLastPathComponent()
        return dir.appendingPathComponent("agentshelf-hook").path
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "Agent Shelf")
        let menu = NSMenu()
        menu.delegate = self          // rebuild each time it opens (reflects live install state)
        item.menu = menu
        statusItem = item
    }

    // Rebuild on open so the hook item and checkmarks always reflect current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let installed = (try? installer.isInstalled()) ?? false

        let header = NSMenuItem(title: "Agent Shelf", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        add(menu, installed ? "Uninstall Claude Code Hooks" : "Install Claude Code Hooks",
            #selector(toggleHooks))

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
            if (try? installer.isInstalled()) == true { try installer.uninstall() }
            else { try installer.install() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Hook update failed"
            alert.informativeText = "\(error)"
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

    @objc private func quit() { NSApp.terminate(nil) }
}
