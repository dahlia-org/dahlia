import SwiftUI

struct MeetingSidebarListGroupLabel: View {
    let title: String
    let isExpanded: Bool
    let onToggleExpansion: () -> Void
    var displayMode: Binding<MeetingSidebarDisplayMode>?

    @State private var isHovered = false
    @FocusState private var isMenuFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
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
            .accessibilityAddTraits(.isHeader)
            .accessibilityHint(isExpanded ? L10n.collapse : L10n.expand)

            if let displayMode {
                MeetingSidebarOrganizationMenu(displayMode: displayMode)
                    .focused($isMenuFocused)
                    .opacity(isHovered || isMenuFocused ? 1 : 0)
            }
        }
        .font(DahliaDesign.sidebarFont)
        .foregroundStyle(DahliaDesign.sidebarSecondaryTextColor)
        .listRowSeparator(.hidden)
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .padding(.vertical, DahliaDesign.sidebarRowVerticalPadding)
    }
}
