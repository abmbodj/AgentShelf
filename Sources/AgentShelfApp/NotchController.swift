import AppKit
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
    private var hoverCancellable: AnyCancellable?

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
        // The library already tracks hover over the whole notch (pill + expanded) —
        // forward it instead of adding our own .onHover on the pill views.
        hoverCancellable = notch?.$isHovering.sink { [weak self] h in self?.setHovering(h) }
        flash()   // proof-of-life: briefly open the panel on launch
    }

    func setHovering(_ h: Bool) { hovering = h; refresh() }
    func togglePin() { pinned.toggle(); refresh() }

    /// True when the user is already looking at the app we'd jump to — routine
    /// flash/sound is noise then. Approvals still surface regardless.
    static var jumpTargetIsFrontmost: Bool {
        let name = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        return ["Cursor", "Visual Studio Code", "Code"].contains(name)
    }

    /// Focus the editor window for a session's folder.
    func jump(_ session: Session) { jump(cwd: session.cwd) }
    func jump(cwd: String) {
        JumpService.focus(cwd: cwd)
        // You're leaving for the session — collapse the shelf so it can't cover whatever
        // opens (e.g. a first-run macOS permission dialog appears top-center too).
        pinned = false
        hovering = false
        Task { await notch?.hide() }
    }

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
        // Fix stale styling on whatever window already exists *before* touching anything
        // async: a burst of hook events (PreToolUse, PermissionRequest, ...) can cancel the
        // previous transition before it ever reaches the styling step below, leaving the panel
        // stuck at DynamicNotchKit's default .screenSaver level — high enough to cover a system
        // TCC "Allow/Don't Allow" dialog. This call is idempotent, so re-running it here on
        // every refresh (not just after a fresh expand) closes that gap unconditionally.
        applyWindowStyle()
        transition?.cancel()
        transition = Task {
            if wantExpand { await notch.expand() }
            else if hasSessions { await notch.compact() }
            else { await notch.hide() }
            // The panel is recreated on each expand (back to .screenSaver), so re-apply here too.
            applyWindowStyle()
        }
    }

    /// Drop the panel below system alerts but keep it above app windows, and keep it out of
    /// Mission Control / fullscreen / screen recordings. Safe to call repeatedly.
    private func applyWindowStyle() {
        guard let window = notch?.windowController?.window else { return }
        window.level = .statusBar
        window.collectionBehavior.formUnion(
            [.fullScreenAuxiliary, .canJoinAllSpaces, .ignoresCycle, .stationary])
        window.sharingType = .readOnly
    }
}
