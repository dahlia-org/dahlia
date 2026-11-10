import SwiftUI

/// Notion-style sidebar menu: icon-only buttons, with the label shown only on the selected one.
struct MainSidebarTabBar: View {
    let selection: MainSidebarTab
    let onSelect: (MainSidebarTab) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(MainSidebarTab.allCases, id: \.self) { tab in
                MainSidebarTabButton(tab: tab, isSelected: tab == selection) { onSelect(tab) }
            }
            Spacer(minLength: 0)
        }
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

private struct MainSidebarTabButton: View {
    let tab: MainSidebarTab
    let isSelected: Bool
    let action: () -> Void

    @Environment(DahliaWindowHeaderHelpController.self) private var helpController
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var helpID = UUID()
    @State private var buttonFrame: CGRect = .zero
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: tab.systemImage)
                    .dahliaFixedSymbol()
                if isSelected {
                    Text(tab.title)
                        .lineLimit(1)
                }
            }
            .font(.body)
            .foregroundStyle(DahliaDesign.sidebarPrimaryTextColor)
            .padding(.horizontal, 8)
            .frame(minHeight: 28)
            .background(
                isSelected || isHovered
                    ? Color.primary.opacity(DahliaDesign.sidebarHighlightOpacity(for: colorSchemeContrast))
                    : .clear,
                in: .rect(cornerRadius: DahliaDesign.Highlight.compactCornerRadius)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(tab.shortcutKey), modifiers: .control)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { buttonFrame = $0 }
        .onHover { isHovering in
            isHovered = isHovering
            if isHovering {
                // Below, because above would cover the window header's controls.
                helpController.hoverBegan(
                    for: helpID,
                    label: tab.title,
                    shortcut: "⌃\(tab.shortcutKey)",
                    buttonFrame: buttonFrame,
                    placesBelow: true
                )
            } else {
                helpController.hoverEnded(for: helpID)
            }
        }
        .onDisappear { helpController.hoverEnded(for: helpID) }
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
