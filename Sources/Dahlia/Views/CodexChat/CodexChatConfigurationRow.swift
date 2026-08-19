import SwiftUI

struct CodexChatConfigurationRow: View {
    let title: String
    let isSelected: Bool
    var leadingSystemImage: String?
    var trailingSystemImage: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let leadingSystemImage {
                    Image(systemName: leadingSystemImage)
                        .dahliaFixedSymbol()
                        .foregroundStyle(DahliaDesign.secondaryTextColor)
                        .accessibilityHidden(true)
                }

                Text(title)
                    .font(.body)
                    .foregroundStyle(DahliaDesign.primaryTextColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 4)

                if isSelected || trailingSystemImage != nil {
                    Image(systemName: trailingSystemImage ?? "checkmark")
                        .dahliaFixedSymbol()
                        .foregroundStyle(DahliaDesign.secondaryTextColor)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isHovering || isSelected ? DahliaDesign.contentHighlightColor : .clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .onHover { isHovering = $0 }
        .accessibilityValue(isSelected ? L10n.selected : "")
    }
}
