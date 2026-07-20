import SwiftUI
import DynamicNotchKit
import AgentShelfCore

/// Owns the DynamicNotch and reconciles its presentation with session state:
/// no sessions -> hidden, sessions -> compact pill, hover/pin/approval -> expanded.
@MainActor
final class NotchController: ObservableObject {
    typealias AppNotch = DynamicNotch<SessionListView, PillLeadingView, PillTrailingView>

    let store: SessionStore
    @Published private(set) var pinned = false
    private var hovering = false
    private var notch: AppNotch?
    private var transition: Task<Void, Never>?

    init(store: SessionStore) { self.store = store }

    func start() {
        notch = DynamicNotch(hoverBehavior: [.keepVisible, .increaseShadow]) {
            SessionListView(store: self.store, controller: self)
        } compactLeading: {
            PillLeadingView(store: self.store)
        } compactTrailing: {
            PillTrailingView(store: self.store)
        }
        refresh()
    }

    func setHovering(_ h: Bool) { hovering = h; refresh() }
    func togglePin() { pinned.toggle(); refresh() }

    /// Focus the editor window for a session's folder.
    func jump(_ session: Session) { JumpService.focus(cwd: session.cwd) }

    /// Reconcile the notch after any state change (sessions, hover, pin).
    func refresh() {
        guard let notch else { return }
        let hasSessions = !store.active.isEmpty
        let wantExpand = pinned || hovering || store.worstStatus == .waitingApproval
        transition?.cancel()
        transition = Task {
            if !hasSessions && !pinned { await notch.hide() }
            else if wantExpand { await notch.expand() }
            else { await notch.compact() }
        }
    }
}
