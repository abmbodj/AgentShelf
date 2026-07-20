import SwiftUI

/// Phase 0 static panel — proves the DynamicNotchKit overlay renders our own
/// SwiftUI content. Phase 1 replaces this with the live session list + approvals.
struct NotchPanelView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agent Shelf")
                .font(.headline)
                .foregroundStyle(.white)
            ForEach(["claude · myrepo", "codex · api"], id: \.self) { row in
                HStack(spacing: 8) {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text(row).foregroundStyle(.white.opacity(0.85))
                }
                .font(.system(.body, design: .rounded))
            }
        }
        .padding(16)
        .frame(width: 260, alignment: .leading)
    }
}
