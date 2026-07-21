import SwiftUI
import Combine
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
    private var flashing = false
    private var notch: AppNotch?
    private var transition: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?
    private var cancellable: AnyCancellable?

    init(store: SessionStore) { self.store = store }

    func start() {
        notch = DynamicNotch(hoverBehavior: [.keepVisible, .increaseShadow]) {
            SessionListView(store: self.store, controller: self)
        } compactLeading: {
            PillLeadingView(store: self.store)
        } compactTrailing: {
            PillTrailingView(store: self.store)
        }
        // Auto-reconcile the notch on any store change (sessions, approvals, notice dismissal),
        // so the store never needs to know about the controller. objectWillChange fires before
        // the mutation commits, hence the main-actor hop.
        cancellable = store.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        flash()   // proof-of-life: briefly open the panel on launch
    }

    func setHovering(_ h: Bool) { hovering = h; refresh() }
    func togglePin() { pinned.toggle(); refresh() }

    /// Focus the editor window for a session's folder.
    func jump(_ session: Session) { jump(cwd: session.cwd) }
    func jump(cwd: String) { JumpService.focus(cwd: cwd) }

    /// Briefly expand to announce activity (launch / new session), then settle back to
    /// the pill (unless hovered/pinned/approval keeps it open).
    func flash() {
        flashing = true
        refresh()
        flashTask?.cancel()
        flashTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            flashing = false
            refresh()
        }
    }

    /// Reconcile the notch after any state change (sessions, hover, pin, flash).
    func refresh() {
        guard let notch else { return }
        let hasSessions = !store.active.isEmpty
        let wantExpand = pinned || hovering || flashing || store.worstStatus == .waitingApproval
        transition?.cancel()
        transition = Task {
            if wantExpand { await notch.expand() }
            else if hasSessions { await notch.compact() }
            else { await notch.hide() }
        }
    }
}
