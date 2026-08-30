import SwiftUI

struct MainSearchFilterButton: View {
    let title: String
    let systemImage: String
    let mode: MainSearchSuggestions.Mode
    @Binding var selection: MainSearchSuggestions.Mode

    @State private var isHovered = false

    var body: some View {
        Button(title, systemImage: systemImage, action: toggleSelection)
            .labelStyle(.iconOnly)
            .dahliaFixedSymbol()
            .buttonStyle(.plain)
            .foregroundStyle(
                selection == mode ? DahliaDesign.primaryTextColor : DahliaDesign.secondaryTextColor
            )
            .frame(width: 28, height: 28)
            .contentShape(.rect)
            .background(
                selection == mode || isHovered ? DahliaDesign.contentHighlightColor : .clear,
                in: .rect(cornerRadius: DahliaDesign.Highlight.regularCornerRadius)
            )
            .onHover { isHovered = $0 }
            .dahliaHoverHelp(label: title)
            .accessibilityAddTraits(selection == mode ? .isSelected : [])
    }

    private func toggleSelection() {
        selection = selection == mode ? .overview : mode
    }
}
