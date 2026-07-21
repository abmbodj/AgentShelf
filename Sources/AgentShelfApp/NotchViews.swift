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
        StatusDot(color: (store.worstStatus ?? .idle).color, diameter: 9)
            .padding(.trailing, 4)
    }
}

/// Expanded panel: the live session list. Hover peeks, click pins (driven by controller).
struct SessionListView: View {
    @ObservedObject var store: SessionStore
    unowned let controller: NotchController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Slim, dim top strip: usage on the left, pin on the right, no wordmark. The whole
            // strip is the pin affordance. Vibrant .secondary reads correctly over glass.
            HStack(spacing: 6) {
                if let usage = UsageCache.text {
                    Text(usage)
                        .font(.caption2).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: controller.pinned ? "pin.fill" : "pin")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { controller.togglePin() }

            // Attention items drop in above the list: a binary Allow/Deny approval, an
            // answerable question, or a read-only "needs input" notice (a choice too rich to
            // answer inline).
            if let approval = store.pendingApprovals.first {
                ApprovalCard(request: approval) { controller.jump(cwd: approval.cwd) }
            } else if let question = store.pendingQuestions.first {
                QuestionCard(request: question) { controller.jump(cwd: question.cwd) }
            } else if let notice = store.pendingNotices.first {
                NeedsInputCard(notice: notice) { controller.jump(cwd: notice.cwd) }
            }

            if store.active.isEmpty {
                Text("Watching Claude Code…").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(store.active) { session in
                    SessionRow(session: session)
                        .contentShape(Rectangle())
                        .onTapGesture { controller.jump(session) }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 16)
        .frame(width: DesignTokens.panelWidth, alignment: .leading)
        // Glass is rendered by the (patched) DynamicNotchKit; the window is forced dark
        // (NotchController) so glass + vibrant text stay legible over any desktop.
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
                    .lineLimit(request.diff.isEmpty ? 3 : 1).truncationMode(.middle)
            }
            if !request.diff.isEmpty {
                DiffView(lines: request.diff)
            }
            HStack(spacing: 8) {
                Button("Deny") { request.decide(.deny) }
                    .buttonStyle(ApprovalButtonStyle(prominent: false))
                // "Always" = allow + session-scoped rule for this tool (nothing on disk).
                Button("Always") { request.decide(.allowAlways) }
                    .buttonStyle(ApprovalButtonStyle(prominent: false))
                Button("Allow") { request.decide(.allow) }
                    .buttonStyle(ApprovalButtonStyle(prominent: true))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius, style: .continuous).fill(DesignTokens.elevatedSurface))
    }
}

/// Filled-pill style for the approval row: three equal-width buttons, dark secondary
/// (Deny/Always) vs. near-white primary (Allow). Not `.glass` — the reference wants solid
/// fills with clear primary/secondary contrast.
// ponytail: colors inline, not DesignTokens — used only here; tune against the real notch.
private struct ApprovalButtonStyle: ButtonStyle {
    var prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(prominent ? Color(white: 0.10) : Color(white: 0.90))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(prominent ? Color(white: 0.95) : Color(white: 0.28))
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Answerable AskUserQuestion (single question, single select): tapping an option injects its
/// ordinal into the terminal that owns the session — Claude Code's menu accepts a bare digit
/// keypress with no Enter needed (verified against 2.1.216). If injection fails (untargetable
/// terminal, no matching window) we fall back to "Open in Claude" rather than leave the card
/// looking answerable with no effect.
struct QuestionCard: View {
    let request: QuestionRequest
    let onOpen: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(.yellow)
                Text("\(request.source.displayName) · \(request.folderName)")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Spacer()
                OpenInClaudeButton { request.dismiss(); onOpen() }
            }
            Text(request.question)
                .font(.callout).foregroundStyle(.white.opacity(0.9))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(request.options.enumerated()), id: \.offset) { index, option in
                    Button {
                        request.choose(index) { Task { @MainActor in request.dismiss(); onOpen() } }
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1)")
                                .font(.caption.weight(.bold)).foregroundStyle(.yellow)
                                .frame(width: 14, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(option.label)
                                    .font(.callout.weight(.medium)).foregroundStyle(.white)
                                if !option.description.isEmpty {
                                    Text(option.description)
                                        .font(.caption2).foregroundStyle(.white.opacity(0.6))
                                        .lineLimit(1).truncationMode(.tail)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.05)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius, style: .continuous).fill(DesignTokens.elevatedSurface))
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
                OpenInClaudeButton(action: onOpen)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius, style: .continuous).fill(DesignTokens.elevatedSurface))
    }
}

/// Colored +/- line diff for an Edit/MultiEdit/Write approval, built by LineDiff
/// (stdlib CollectionDifference — no dependency). Clamped so a large file edit can't
/// blow out the notch's height; the summary line above already names the file.
struct DiffView: View {
    let lines: [DiffLine]
    private let maxLines = 8

    private var window: (lines: [DiffLine], hiddenBefore: Int, hiddenAfter: Int) {
        LineDiff.windowed(lines, maxLines: maxLines)
    }

    var body: some View {
        let w = window
        VStack(alignment: .leading, spacing: 0) {
            if w.hiddenBefore > 0 {
                Text("⋯ \(w.hiddenBefore) lines above")
                    .font(.caption2).foregroundStyle(.white.opacity(0.4))
                    .padding(.bottom, 2)
            }
            ForEach(Array(w.lines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 6) {
                    Text("\(line.lineNumber)")
                        .foregroundStyle(.white.opacity(0.3))
                        .frame(width: 24, alignment: .trailing)
                    Text(marker(for: line.kind))
                        .foregroundStyle(color(for: line.kind))
                    Text(line.text)
                        .foregroundStyle(line.kind == .context ? .white.opacity(0.7) : .white.opacity(0.95))
                        .lineLimit(1).truncationMode(.tail)
                }
                .font(.system(.caption2, design: .monospaced))
            }
            if w.hiddenAfter > 0 {
                Text("⋯ \(w.hiddenAfter) lines below")
                    .font(.caption2).foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 2)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(DesignTokens.insetSurface))
    }

    private func marker(for kind: DiffLine.Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "-"
        case .context: return " "
        }
    }

    private func color(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: return .green
        case .removed: return .red
        case .context: return .white.opacity(0.3)
        }
    }
}

private struct OpenInClaudeButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label("Open in Claude", systemImage: "arrow.up.right.square")
                .font(.caption)
        }
        .buttonStyle(.glass)
    }
}

struct SessionRow: View {
    let session: Session
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                if session.isSubagent {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                StatusDot(color: session.status.color, diameter: session.isSubagent ? 7 : 9)
                Text(session.displayLabel)
                    .font(.system(size: session.isSubagent ? 13 : 14, weight: .semibold))
                    .tracking(-0.1)
                    .foregroundStyle(.primary)
                // Subagents share the parent's folder — skip it, the branch glyph already implies it.
                if !session.isSubagent {
                    Text(folderLine)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                if let terminal = session.terminalLabel {
                    TagPill(text: terminal)
                }
                Spacer()
                Text(session.ageLabel)
                    .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
            }
            if let prompt = session.lastUserPrompt {
                Text("You: \(prompt)")
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.leading, 17)
            }
            if let activity = session.activityLabel {
                Text(activity)
                    .font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.leading, 17)
            }
        }
        .padding(.vertical, 2)
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

/// Status dot with a soft status-colored glow, so state reads at a glance on the glass.
private struct StatusDot: View {
    let color: Color
    let diameter: CGFloat
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .shadow(color: color.opacity(0.7), radius: diameter * 0.45)
    }
}

/// Small capsule badge for a row's terminal tag ("iTerm", "Terminal", "Ghostty").
private struct TagPill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(.white.opacity(0.12)))
    }
}
