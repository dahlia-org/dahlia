import SwiftUI

struct MeetingSidebarHeader: View {
    let title: String
    let isExpanded: Bool
    let onToggleExpansion: () -> Void
    /// A brand mark before the title, such as Omnigent's.
    var icon: Image?
    /// Shows a hover-revealed button that adds an item to the section, such as a project or a chat.
    var addButtonTitle: String?
    var addButtonSystemImage = "plus"
    var canAdd = true
    var onAdd: () -> Void = {}

    @State private var isHovered = false
    @FocusState private var isAddButtonFocused: Bool

    var body: some View {
        HStack {
            Button(action: onToggleExpansion) {
                HStack(spacing: 5) {
                    if let icon {
                        icon
                            .resizable()
                            .scaledToFit()
                            .frame(width: DahliaTypography.size(offset: -2), height: DahliaTypography.size(offset: -2))
                            .accessibilityHidden(true)
                    }
                    Text(title)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.dahliaSecondary)
                        .opacity(!isExpanded || isHovered ? 1 : 0)
                }
            }
            .buttonStyle(.plain)
            .font(.dahliaSectionHeader)
            .accessibilityAddTraits(.isHeader)
            .accessibilityHint(isExpanded ? L10n.collapse : L10n.expand)

            Spacer()

            if let addButtonTitle {
                Button(addButtonTitle, systemImage: addButtonSystemImage, action: onAdd)
                    .labelStyle(.iconOnly)
                    .dahliaFixedSymbol()
                    .buttonStyle(.plain)
                    .focused($isAddButtonFocused)
                    .disabled(!canAdd)
                    .help(addButtonTitle)
                    .opacity(isHovered || isAddButtonFocused ? 1 : 0)
            }
        }
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .foregroundStyle(DahliaDesign.sidebarSecondaryTextColor)
        .padding(.vertical, DahliaDesign.sidebarRowVerticalPadding)
    }
}
