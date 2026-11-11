import SwiftUI

struct CodexChatConfigurationRow: View {
    let title: String
    let isSelected: Bool
    var isEnabled = true
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
                    .font(.dahliaBody)
                    .foregroundStyle(isEnabled ? DahliaDesign.primaryTextColor : DahliaDesign.optionalTextColor)
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
            .frame(height: CodexChatDesign.configurationRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .background(
            isHovering && isEnabled || isSelected ? DahliaDesign.contentHighlightColor : .clear,
            in: .rect(corners: .concentric(
                minimum: .fixed(DahliaDesign.Highlight.regularCornerRadius)
            ))
        )
        .onHover { isHovering = $0 }
        .accessibilityValue(isSelected ? L10n.selected : "")
    }
}
