import AppKit
import AgentShelfCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SessionStore()
    lazy var controller = NotchController(store: store)
    let server = UnixSocketServer(path: AgentShelf.socketPath)

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
        // @MainActor classes are implicitly Sendable, so capturing them here is safe;
        // we hop back onto the main actor to mutate state.
        do {
            try server.start { [store, controller] msg in
                // Phase 1c: status-only. PermissionRequest approval round-trip lands in 1d.
                Task { @MainActor in
                    store.apply(msg)
                    controller.refresh()
                    if ProcessInfo.processInfo.environment["AGENTSHELF_DEBUG"] != nil {
                        NSLog("AgentShelf: \(msg.event) \(msg.source.displayName) sessions=\(store.active.count) worst=\(store.worstStatus?.label ?? "-")")
                    }
                }
                return nil
            }
        } catch {
            NSLog("AgentShelf: socket server failed to start: \(error)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu-bar/agent app, no Dock icon
app.run()
