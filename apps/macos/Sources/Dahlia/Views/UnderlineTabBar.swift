import SwiftUI

/// Text tabs with an underline under the selected one, as the meeting page switches its content.
struct UnderlineTabBar<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let label: (Tab) -> String
    var keyboardShortcut: ((Tab) -> KeyEquivalent)?
    var isDisabled = false
    let accessibilityLabel: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionIndicator
    @State private var hoveredTab: Tab?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(tabs) { tab in
                    let isSelected = tab == selection

                    Button {
                        select(tab)
                    } label: {
                        ZStack {
                            Text(label(tab))
                                .font(.body.weight(.semibold))
                                .hidden()
                            Text(label(tab))
                                .font(isSelected ? .body.weight(.semibold) : .body)
                        }
                        .padding(.horizontal, DahliaDesign.tabHorizontalPadding)
                        .padding(.vertical, DahliaDesign.tabVerticalPadding)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isSelected ? DahliaDesign.primaryTextColor : DahliaDesign.secondaryTextColor)
                    .background {
                        if !isDisabled, hoveredTab == tab {
                            RoundedRectangle(cornerRadius: DahliaDesign.Highlight.compactCornerRadius)
                                .fill(DahliaDesign.contentHighlightColor)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if isSelected {
                            Capsule()
                                .fill(.primary)
                                .frame(height: DahliaDesign.tabIndicatorHeight)
                                .padding(.horizontal, 8)
                                .matchedGeometryEffect(id: "tab-selection", in: selectionIndicator)
                        }
                    }
                    .onHover { hovering in
                        guard !isDisabled else { return }
                        if hovering {
                            hoveredTab = tab
                        } else if hoveredTab == tab {
                            hoveredTab = nil
                        }
                    }
                    .keyboardShortcut(keyboardShortcut.map { KeyboardShortcut($0(tab), modifiers: .command) })
                    .help(label(tab))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .scrollIndicators(.hidden)
        .disabled(isDisabled)
        .onChange(of: isDisabled) { _, disabled in
            if disabled {
                hoveredTab = nil
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func select(_ tab: Tab) {
        guard tab != selection else { return }
        if reduceMotion {
            selection = tab
        } else {
            withAnimation(.easeInOut(duration: 0.18)) {
                selection = tab
            }
        }
    }
}
