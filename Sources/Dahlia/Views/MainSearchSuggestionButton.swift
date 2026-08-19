import SwiftUI

struct MainSearchSuggestionButton: View {
    let title: String
    var systemImage: String?
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .dahliaFixedSymbol()
                        .foregroundStyle(DahliaDesign.secondaryTextColor)
                }
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .dahliaFixedSymbol()
                        .foregroundStyle(DahliaDesign.secondaryTextColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(
            isSelected || isHovered ? DahliaDesign.contentHighlightColor : .clear,
            in: .rect(cornerRadius: DahliaDesign.Highlight.regularCornerRadius)
        )
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
