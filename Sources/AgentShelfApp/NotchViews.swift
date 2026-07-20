import SwiftUI
import AgentShelfCore

/// Compact pill, leading half: agent glyph + active count.
struct PillLeadingView: View {
    @ObservedObject var store: SessionStore
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "cpu")
                .font(.system(size: 11, weight: .semibold))
            Text("\(store.active.count)")
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Agent Shelf").font(.headline).foregroundStyle(.white)
                Spacer()
                if controller.pinned {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.white.opacity(0.6))
                }
            }
            if store.active.isEmpty {
                Text("No active sessions").font(.callout).foregroundStyle(.white.opacity(0.5))
            } else {
                ForEach(store.active) { session in
                    SessionRow(session: session)
                }
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .onHover { controller.setHovering($0) }
        .onTapGesture { controller.togglePin() }
    }
}

struct SessionRow: View {
    let session: Session
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(session.status.color).frame(width: 8, height: 8)
            Text(session.source.displayName)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(.white)
            Text(session.folderName)
                .font(.body).foregroundStyle(.white.opacity(0.7))
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(session.status.label)
                .font(.caption).foregroundStyle(session.status.color)
        }
    }
}
