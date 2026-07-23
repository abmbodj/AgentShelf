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
    /// Session ids currently in their ephemeral post-Stop flash (turn just completed) — each
    /// entry drives that one row's checkmark glow for ~1.5s and then expires on its own timer.
    /// Purely visual: the row's "Done" text itself is a durable idle-state label (see
    /// `SessionRow.activityLine`) and doesn't depend on this set.
    @Published private(set) var justCompletedSessionIDs: Set<String> = []
    private var hovering = false
    private var flashing = false
    /// True right after `jump(cwd:)`, until the mouse actually leaves the notch (or a short
    /// backstop timeout fires). The user's cursor is still physically over the panel they just
    /// clicked in, so DynamicNotchKit's own hover tracking reports one more "still hovering"
    /// callback a beat later — without this, that stale event re-opens the panel we just tried
    /// to close, making the jump look like it did nothing but flash the pill.
    private var suppressHoverExpand = false
    private var notch: AppNotch?
    private var transition: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?
    /// One expiry task per session currently flashing "Done" — keyed by session id so each
    /// flash times out independently of any others in flight.
    private var doneTasks: [String: Task<Void, Never>] = [:]
    private var suppressHoverTask: Task<Void, Never>?
    private var cancellable: AnyCancellable?
    private var hoverCancellable: AnyCancellable?

    init(store: SessionStore) { self.store = store }

    func start() {
        // .auto never actually reaches DynamicNotchKit's custom-radii branch (it pattern-matches
        // on the style stored at construction, and .auto only resolves shape/material choice, not
        // radii) — so radii must be passed explicitly, replicating .auto's own screen-based
        // .notch/.floating branching ourselves via the same public NSScreen APIs.
        let style: DynamicNotchStyle = NSScreen.screens.first?.realNotchSize != nil
            ? .notch(topCornerRadius: DesignTokens.expandedTopCornerRadius,
                     bottomCornerRadius: DesignTokens.expandedBottomCornerRadius)
            : .floating(cornerRadius: 20)
        notch = DynamicNotch(hoverBehavior: [.keepVisible, .increaseShadow], style: style) {
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

    func setHovering(_ h: Bool) {
        if suppressHoverExpand {
            guard !h else { return }   // stale "still hovering" beat right after a jump — ignore it
            suppressHoverExpand = false   // mouse actually left; a fresh hover-in is legitimate again
            suppressHoverTask?.cancel()
        }
        hovering = h
        refresh()
    }
    func togglePin() { pinned.toggle(); refresh() }

    /// True when the user is already looking at the app we'd jump to — routine
    /// flash/sound is noise then. Approvals still surface regardless.
    static var jumpTargetIsFrontmost: Bool {
        let name = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        return ["Cursor", "Visual Studio Code", "Code"].contains(name)
    }

    /// Focus the editor window for a session's folder — or, if it's a Claude Code session
    /// running in one of Cursor's own integrated-terminal tabs, the exact tab.
    func jump(_ session: Session) {
        jump(cwd: session.cwd, tty: session.tty, marker: session.id, terminal: session.terminal)
    }
    func jump(cwd: String, tty: String? = nil, marker: String? = nil, terminal: String? = nil) {
        // Off the main actor: CursorTabFocuser's Accessibility calls and JumpService's Process
        // launch can both block for seconds — or indefinitely on a one-time "Allow AgentShelf to
        // control your computer" permission prompt — and that must never freeze the notch's UI
        // (same precedent as QuestionRequest.choose's terminal injection).
        Task.detached {
            // 1. IDE integrated terminal (Cursor) — exact tab via the tagged tty.
            if let tty, let marker, CursorTabFocuser.focus(tty: tty, marker: marker) { return }
            // 2. Standalone terminal — exact tab/pane where scriptable, else raise its app.
            if TerminalJump.focus(terminal: terminal, cwd: cwd, tty: tty) { return }
            // 3. Editor fallback — open the folder in Cursor/VS Code.
            JumpService.focus(cwd: cwd)
        }
        // You're leaving for the session — collapse the shelf so it can't cover whatever
        // opens (e.g. a first-run macOS permission dialog appears top-center too).
        pinned = false
        hovering = false
        cancelDone()
        // The click that triggered this happened with the mouse over the notch, so a stale
        // "still hovering" callback is coming — ignore hover-driven expansion until the mouse
        // actually leaves. The 1.5s backstop guards against ever getting stuck suppressed if a
        // leave event never arrives for some reason.
        suppressHoverExpand = true
        suppressHoverTask?.cancel()
        suppressHoverTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            suppressHoverExpand = false
        }
        // Route through the same reconciliation path refresh() everywhere else uses, rather than
        // an untracked hide() task, so this can't race the refresh() the store's own change
        // (the request being dismissed) is about to schedule.
        refresh()
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

    /// Turn-complete beat for one session: open the shelf, flash that session's checkmark
    /// glow (~1.5s) + approval sound — the row's "Done" text itself already showed the moment
    /// `Stop` set the session idle, and stays up well after this flash ends. Fully quiet when
    /// the jump target is frontmost; if already expanded, still shows the flash/sound.
    func announceDone(sessionID: String) {
        guard !Self.jumpTargetIsFrontmost else { return }
        justCompletedSessionIDs.insert(sessionID)
        ApprovalSound.play()
        refresh()
        doneTasks[sessionID]?.cancel()
        doneTasks[sessionID] = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            justCompletedSessionIDs.remove(sessionID)
            doneTasks.removeValue(forKey: sessionID)
            refresh()
        }
    }

    /// Drop all in-flight Done flashes immediately (approvals win).
    private func cancelDone() {
        for task in doneTasks.values { task.cancel() }
        doneTasks.removeAll()
        if !justCompletedSessionIDs.isEmpty {
            justCompletedSessionIDs.removeAll()
        }
    }

    /// Reconcile the notch after any state change (sessions, hover, pin, flash, Done).
    func refresh() {
        guard let notch else { return }
        // Decisions beat acknowledgements: clear Done as soon as attention arrives.
        if store.hasAttention || store.worstStatus == .waitingApproval {
            cancelDone()
        }
        let hasSessions = !store.active.isEmpty
        let wantExpand = pinned || hovering || flashing || !justCompletedSessionIDs.isEmpty
            || store.worstStatus == .waitingApproval
        // Fix stale styling on whatever window already exists *before* touching anything
        // async: a burst of hook events (PreToolUse, PermissionRequest, ...) can cancel the
        // previous transition before it ever reaches the styling step below, leaving the panel
        // stuck at DynamicNotchKit's default .screenSaver level — high enough to cover a system
        // TCC "Allow/Don't Allow" dialog. This call is idempotent, so re-running it here on
        // every refresh (not just after a fresh expand) closes that gap unconditionally.
        applyWindowStyle()
        transition?.cancel()
        transition = Task {
            // Coalesce a burst of store mutations (e.g. several PreToolUse/PostToolUse events
            // landing within milliseconds of each other) into one settled call below. Each call
            // to DynamicNotch's expand()/compact() that finds a window already open spawns its
            // own internal, uncancellable close-then-reopen Task (see the vendored
            // DynamicNotch._expand/_compact "already has window" branches) — cancelling our own
            // `transition` here does not stop those, so firing one per event can leave two of
            // them racing and the panel briefly rendered for a stale intermediate size. A short
            // debounce means only the last event in a burst actually triggers a transition.
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
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
        // Lock the panel to dark: keeps the Liquid Glass in its dark variant and vibrant text
        // legible regardless of what's on the desktop behind the see-through panel.
        window.appearance = NSAppearance(named: .darkAqua)
    }
}
