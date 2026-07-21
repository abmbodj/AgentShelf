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
        // If the user already opted into hooks, keep them current across app updates
        // (adds newly-required own-events like SessionEnd; surgical, never touches others).
        menuBar.reconcileHooksIfInstalled()
        // @MainActor classes are implicitly Sendable, so capturing them here is safe;
        // we hop back onto the main actor to mutate state.
        do {
            try server.start { [store, controller] msg in
                switch msg.permissionKind {
                case .binary:
                    // Block this connection thread until the user decides or we hit our own
                    // deadline (< the hook's), then hand the decision back to the hook.
                    // The deadline is ~24h — the card waits for a human; "Open in Claude"
                    // resolves early with nil to bail back to Claude's own prompt.
                    let sem = DispatchSemaphore(value: 0)
                    let box = DecisionBox()
                    Task { @MainActor in
                        store.presentApproval(msg) { decision in box.set(decision); sem.signal() }
                        controller.flash()
                    }
                    let outcome = sem.wait(timeout: .now() + AgentShelf.appDecisionTimeout)
                    Task { @MainActor in store.removeApproval(sessionId: msg.sessionId) }
                    return outcome == .timedOut ? nil : box.get()

                case .nonBinary:
                    // A choice, not a grant: don't block. Notify + let Claude's own prompt drive.
                    Task { @MainActor in
                        let quiet = NotchController.jumpTargetIsFrontmost
                        store.presentNeedsInput(msg, quiet: quiet)
                        if !quiet { controller.flash() }
                    }
                    return nil

                case .none:
                    Task { @MainActor in
                        if msg.event == "SessionEnd" {
                            store.endSession(msg.sessionId)
                        } else {
                            let isNew = store.apply(msg)
                            // New-session flash is noise if you're already in the editor.
                            if isNew, !NotchController.jumpTargetIsFrontmost { controller.flash() }
                        }
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

// Single-instance guard: if another Agent Shelf is already running (same bundle id),
// bow out so two instances don't fight over the socket. No-op for the raw binary.
let me = NSRunningApplication.current
let duplicate = NSRunningApplication
    .runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.agentshelf.app")
    .contains { $0.processIdentifier != me.processIdentifier }
if duplicate { exit(0) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu-bar/agent app, no Dock icon
app.run()
