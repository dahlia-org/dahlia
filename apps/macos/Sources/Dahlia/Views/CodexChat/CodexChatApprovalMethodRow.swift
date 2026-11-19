import SwiftUI

struct CodexChatApprovalMethodRow: View {
    let method: CodexChatApprovalMethod
    let description: String
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: method.systemImage)
                    .dahliaFixedSymbol()
                    .frame(width: 20)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(method.title)
                        .font(.dahliaBody)
                    Text(description)
                        .font(.dahliaBody)
                        .foregroundStyle(DahliaDesign.optionalTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .dahliaFixedSymbol()
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(isEnabled ? DahliaDesign.primaryTextColor : DahliaDesign.optionalTextColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .background(
            (isHovering && isEnabled) || isSelected ? DahliaDesign.contentHighlightColor : .clear,
            in: .rect(corners: .concentric(
                minimum: .fixed(DahliaDesign.Highlight.regularCornerRadius)
            ))
        )
        .onHover { isHovering = $0 }
        .accessibilityValue(isSelected ? L10n.selected : "")
        .accessibilityHint(description)
    }
}
