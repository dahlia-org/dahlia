import SwiftUI

struct MeetingSidebarListGroupLabel: View {
    let title: String
    let isExpanded: Bool
    let onToggleExpansion: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onToggleExpansion) {
            HStack(spacing: 5) {
                Text(title)
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .opacity(!isExpanded || isHovered ? 1 : 0)
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .font(DahliaDesign.sidebarFont)
        .foregroundStyle(.tertiary)
        .accessibilityAddTraits(.isHeader)
        .accessibilityHint(isExpanded ? L10n.collapse : L10n.expand)
        .listRowSeparator(.hidden)
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .padding(.vertical, DahliaDesign.sidebarRowVerticalPadding)
    }
}
