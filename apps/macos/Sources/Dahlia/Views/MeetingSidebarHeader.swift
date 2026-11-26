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
    /// How many items the section holds. With a count the header takes T3 Code's layout: the count and the chevron at
    /// the trailing edge, and the add button in the count's place while hovered.
    var count: Int?
    /// Whether the count also shows while the section is expanded.
    var showsCountWhenExpanded = false

    @State private var isHovered = false
    @FocusState private var isAddButtonFocused: Bool

    var body: some View {
        if let count {
            countedBody(count)
        } else {
            plainBody
        }
    }

    private func countedBody(_ count: Int) -> some View {
        HStack(spacing: 6) {
            Button(action: onToggleExpansion) {
                HStack(spacing: 5) {
                    Text(title)
                    Spacer(minLength: 8)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .font(.dahliaSectionHeader)
            .accessibilityAddTraits(.isHeader)
            .accessibilityHint(isExpanded ? L10n.collapse : L10n.expand)
            .accessibilityValue(Text(count, format: .number))

            ZStack(alignment: .trailing) {
                Text(count, format: .number)
                    .font(.dahliaSecondary)
                    .monospacedDigit()
                    .opacity(showsAddButton || !(showsCountWhenExpanded || !isExpanded) ? 0 : 1)
                    .accessibilityHidden(true)
                if let addButtonTitle {
                    addButton(addButtonTitle).opacity(showsAddButton ? 1 : 0).allowsHitTesting(showsAddButton)
                }
            }

            Button(action: onToggleExpansion) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.dahliaSecondary)
                    .frame(width: 12)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
        }
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .foregroundStyle(DahliaDesign.sidebarSecondaryTextColor)
        .padding(.vertical, DahliaDesign.sidebarRowVerticalPadding)
    }

    private var showsAddButton: Bool { addButtonTitle != nil && (isHovered || isAddButtonFocused) }

    private func addButton(_ title: String) -> some View {
        Button(title, systemImage: addButtonSystemImage, action: onAdd)
            .labelStyle(.iconOnly)
            .dahliaFixedSymbol()
            .buttonStyle(.plain)
            .focused($isAddButtonFocused)
            .disabled(!canAdd)
            .modifier(SidebarHoverHelp(label: title))
    }

    private var plainBody: some View {
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
                    .modifier(SidebarHoverHelp(label: addButtonTitle))
                    .opacity(isHovered || isAddButtonFocused ? 1 : 0)
            }
        }
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .foregroundStyle(DahliaDesign.sidebarSecondaryTextColor)
        .padding(.vertical, DahliaDesign.sidebarRowVerticalPadding)
    }
}

/// The sidebar's dark hover help. A `List` row clips an overlay of its own, so the sidebar's overlay
/// (`mainSidebarHelpOverlay`) draws it, as for the upcoming-event row.
private struct SidebarHoverHelp: ViewModifier {
    let label: String

    @Environment(DahliaWindowHeaderHelpController.self) private var helpController
    @State private var helpID = UUID()
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .onHover { isHovering in
                if isHovering {
                    helpController.hoverBegan(for: helpID, label: label, shortcut: nil, buttonFrame: frame)
                } else {
                    helpController.hoverEnded(for: helpID)
                }
            }
            .onDisappear { helpController.hoverEnded(for: helpID) }
            .accessibilityHint(label)
    }
}
