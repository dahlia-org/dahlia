import SwiftUI

/// Notion-style tab bar: icon-only buttons, with the label shown only on the selected one.
struct IconTabBar<Tab: Hashable>: View {
    let tabs: [Tab]
    let selection: Tab
    let title: (Tab) -> String
    let systemImage: (Tab) -> String
    /// A ⌃ shortcut per tab; nil leaves the tab without one.
    var shortcutKey: (Tab) -> Character? = { _ in nil }
    let onSelect: (Tab) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.self) { tab in
                IconTabButton(
                    title: title(tab),
                    systemImage: systemImage(tab),
                    shortcutKey: shortcutKey(tab),
                    isSelected: tab == selection
                ) { onSelect(tab) }
            }
            Spacer(minLength: 0)
        }
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

private struct IconTabButton: View {
    let title: String
    let systemImage: String
    let shortcutKey: Character?
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
                Image(systemName: systemImage)
                    .dahliaFixedSymbol()
                if isSelected {
                    Text(title)
                        .lineLimit(1)
                }
            }
            .font(.dahliaBody)
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
        .keyboardShortcut(shortcutKey.map { KeyboardShortcut(KeyEquivalent($0), modifiers: .control) })
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { buttonFrame = $0 }
        .onHover { isHovering in
            isHovered = isHovering
            if isHovering {
                // Below, because above would cover the window header's controls.
                helpController.hoverBegan(
                    for: helpID,
                    label: title,
                    shortcut: shortcutKey.map { "⌃\($0)" },
                    buttonFrame: buttonFrame,
                    placesBelow: true
                )
            } else {
                helpController.hoverEnded(for: helpID)
            }
        }
        .onDisappear { helpController.hoverEnded(for: helpID) }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
