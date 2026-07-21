import SwiftUI
import AgentShelfCore

/// Compact pill, leading half: agent glyph + active count.
struct PillLeadingView: View {
    @ObservedObject var store: SessionStore
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "cpu")
                .font(.system(size: 11, weight: .semibold))
            Text("\(store.topLevelCount)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.leading, 4)
    }
}

/// Compact pill, trailing half: worst-status dot.
struct PillTrailingView: View {
    @ObservedObject var store: SessionStore
    var body: some View {
        Circle()
            .fill((store.worstStatus ?? .idle).color)
            .frame(width: 9, height: 9)
            .padding(.trailing, 4)
    }
}

/// Expanded panel: the live session list. Hover peeks, click pins (driven by controller).
struct SessionListView: View {
    @ObservedObject var store: SessionStore
    unowned let controller: NotchController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Agent Shelf").font(.headline).foregroundStyle(.white)
                Spacer()
                Image(systemName: controller.pinned ? "pin.fill" : "pin")
                    .font(.caption2).foregroundStyle(.white.opacity(0.6))
            }
            .contentShape(Rectangle())
            .onTapGesture { controller.togglePin() }

            // Attention items drop in above the list: a binary Allow/Deny approval, or a
            // non-binary "needs input" notice (a choice the notch can't make for you).
            if let approval = store.pendingApprovals.first {
                ApprovalCard(request: approval) { controller.jump(cwd: approval.cwd) }
            } else if let notice = store.pendingNotices.first {
                NeedsInputCard(notice: notice) { controller.jump(cwd: notice.cwd) }
            }

            if store.active.isEmpty {
                Text("Watching Claude Code…").font(.callout).foregroundStyle(.white.opacity(0.5))
            } else {
                ForEach(store.active) { session in
                    SessionRow(session: session)
                        .contentShape(Rectangle())
                        .onTapGesture { controller.jump(session) }
                }
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }
}

/// Auto-dropped binary permission prompt: Allow/Deny, plus an escape to Claude's full prompt.
struct ApprovalCard: View {
    let request: ApprovalRequest
    let onOpen: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
                Text("\(request.source.displayName) · \(request.folderName)")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Spacer()
                // Hand the prompt back (no reply) so Claude's own prompt is live on arrival.
                OpenInClaudeButton { request.pass(); onOpen() }
            }
            Text(request.toolName).font(.caption.weight(.bold)).foregroundStyle(.orange)
            if !request.toolSummary.isEmpty {
                Text(request.toolSummary)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(3).truncationMode(.middle)
            }
            HStack {
                Button("Deny") { request.decide(.deny) }.buttonStyle(.bordered)
                Spacer()
                // "Always" = allow + session-scoped rule for this tool (nothing on disk).
                Button("Always") { request.decide(.allowAlways) }.buttonStyle(.bordered)
                Button("Allow") { request.decide(.allow) }.buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08)))
    }
}

/// Non-binary prompt (a choice, not a grant): the notch can't decide it — it just points you
/// to Claude's own multi-option prompt. No Allow/Deny (that would misrepresent the choice).
struct NeedsInputCard: View {
    let notice: AttentionNotice
    let onOpen: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(.yellow)
                Text("\(notice.source.displayName) · \(notice.folderName) needs your input")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
            }
            Text(notice.toolName).font(.caption.weight(.bold)).foregroundStyle(.yellow)
            HStack {
                Spacer()
                OpenInClaudeButton(action: onOpen).buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08)))
    }
}

private struct OpenInClaudeButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label("Open in Claude", systemImage: "arrow.up.right.square")
                .font(.caption)
        }
    }
}

struct SessionRow: View {
    let session: Session
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                if session.isSubagent {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                }
                Circle().fill(session.status.color)
                    .frame(width: session.isSubagent ? 6 : 8, height: session.isSubagent ? 6 : 8)
                Text(session.displayLabel)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
                // Subagents share the parent's folder — skip it, the branch glyph already implies it.
                if !session.isSubagent {
                    Text(folderLine)
                        .font(.body).foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text(session.status.label)
                    .font(.caption).foregroundStyle(session.status.color)
            }
            if let tool = session.lastTool {
                Text("\(tool) · \(session.ageLabel)")
                    .font(.caption2).foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.leading, 16)
            }
        }
        .padding(.leading, session.isSubagent ? 16 : 0)
    }

    /// "folder (branch)" — branch via a 30s TTL cache; never resolve VCS in a view
    /// body uncached (upstream's 99%-CPU incident).
    private var folderLine: String {
        if let branch = BranchCache.branch(for: session.cwd) {
            return "\(session.folderName) (\(branch))"
        }
        return session.folderName
    }
}
