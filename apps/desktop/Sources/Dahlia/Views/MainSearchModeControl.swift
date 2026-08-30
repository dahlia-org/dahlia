import SwiftUI

struct MainSearchModeControl: View {
    @Binding var selection: SearchMode
    let allowsNeuralSearch: Bool

    @State private var isPresented = false
    @State private var isHovering = false
    @State private var hoveredMode: SearchMode?

    var body: some View {
        Button(action: { isPresented.toggle() }) {
            HStack(spacing: 7) {
                Image(systemName: "slider.horizontal.3")
                    .dahliaFixedSymbol()
                    .accessibilityHidden(true)
                Text(title(for: selection))
                    .font(.subheadline)
                    .bold()
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(DahliaDesign.primaryTextColor)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(
            isPresented || isHovering ? DahliaDesign.chipHoverColor : DahliaDesign.contentHighlightColor,
            in: .rect(cornerRadius: DahliaDesign.Field.cornerRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: DahliaDesign.Field.cornerRadius)
                .stroke(.separator, lineWidth: 1)
        }
        .onHover { isHovering = $0 }
        .accessibilityLabel(L10n.searchMode)
        .accessibilityValue(title(for: selection))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(spacing: 2) {
                ForEach(SearchMode.allCases.filter { $0 != .neural || allowsNeuralSearch }, id: \.self) { mode in
                    Button(action: { select(mode) }) {
                        HStack(spacing: 8) {
                            Text(title(for: mode))
                                .font(.body)
                            Spacer(minLength: 16)
                            if mode == selection {
                                Image(systemName: "checkmark")
                                    .dahliaFixedSymbol()
                                    .accessibilityHidden(true)
                            }
                        }
                        .foregroundStyle(DahliaDesign.primaryTextColor)
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .background(
                        hoveredMode == mode ? DahliaDesign.contentHighlightColor : .clear,
                        in: .rect(cornerRadius: DahliaDesign.Highlight.compactCornerRadius)
                    )
                    .onHover { isHovered in
                        hoveredMode = isHovered ? mode : nil
                    }
                    .accessibilityAddTraits(mode == selection ? .isSelected : [])
                }
            }
            .padding(6)
            .frame(width: 180)
        }
    }

    private func select(_ mode: SearchMode) {
        selection = mode
        isPresented = false
    }

    private func title(for mode: SearchMode) -> String {
        switch mode {
        case .simple: L10n.searchModeSimple
        case .advanced: L10n.searchModeAdvanced
        case .neural: L10n.searchModeNeural
        }
    }
}
