import AppKit
import SwiftUI
import DynamicNotchKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Concrete generic type: convenience init -> EmptyView compact slots.
    var notch: DynamicNotch<NotchPanelView, EmptyView, EmptyView>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let notch = DynamicNotch { NotchPanelView() }
        self.notch = notch
        Task { await notch.expand() }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu-bar/agent app, no Dock icon
app.run()
