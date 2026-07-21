import AppKit
import AgentShelfCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SessionStore()
    lazy var controller = NotchController(store: store)
    let server = UnixSocketServer(path: AgentShelf.socketPath)
    let menuBar = MenuBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
        menuBar.install()
        // @MainActor classes are implicitly Sendable, so capturing them here is safe;
        // we hop back onto the main actor to mutate state.
        do {
            try server.start { [store, controller] msg in
                switch msg.permissionKind {
                case .binary:
                    // Block this connection thread until the user decides or we hit our own
                    // deadline (< the hook's), then hand the decision back to the hook.
                    let sem = DispatchSemaphore(value: 0)
                    let box = DecisionBox()
                    Task { @MainActor in
                        store.presentApproval(msg) { decision in box.set(decision); sem.signal() }
                        controller.flash()
                    }
                    let outcome = sem.wait(timeout: .now() + 55)
                    Task { @MainActor in store.removeApproval(sessionId: msg.sessionId) }
                    return outcome == .timedOut ? nil : box.get()

                case .nonBinary:
                    // A choice, not a grant: don't block. Notify + let Claude's own prompt drive.
                    Task { @MainActor in
                        store.presentNeedsInput(msg)
                        controller.flash()
                    }
                    return nil

                case .none:
                    Task { @MainActor in
                        let isNew = store.apply(msg)
                        if isNew { controller.flash() }
                        if ProcessInfo.processInfo.environment["AGENTSHELF_DEBUG"] != nil {
                            NSLog("AgentShelf: \(msg.event) \(msg.source.displayName) sessions=\(store.active.count) worst=\(store.worstStatus?.label ?? "-")")
                        }
                    }
                    return nil
                }
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
