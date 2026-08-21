import SwiftUI

struct CodexChatApprovalMethodRow: View {
    let method: CodexChatApprovalMethod
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: method.systemImage)
                    .dahliaFixedSymbol()
                    .frame(width: 18)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(method.title)
                        .font(.body)
                    Text(method.description)
                        .font(.callout)
                        .foregroundStyle(method == .fullAccess ? Color.orange : DahliaDesign.optionalTextColor)
                        .lineLimit(1)
                    if method == .autoReview, !isEnabled {
                        Text(L10n.chatApprovalAutoReviewRequiresSubscription)
                            .font(.callout)
                            .foregroundStyle(DahliaDesign.optionalTextColor)
                    }
                }

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .dahliaFixedSymbol()
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(method == .fullAccess ? Color.orange : DahliaDesign.primaryTextColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isHovering || isSelected ? DahliaDesign.contentHighlightColor : .clear,
            in: .rect(corners: .concentric(
                minimum: .fixed(DahliaDesign.Highlight.regularCornerRadius)
            ))
        )
        .onHover { isHovering = $0 }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityValue(isSelected ? L10n.selected : "")
        .accessibilityHint(isEnabled ? method.description : L10n.chatApprovalAutoReviewRequiresSubscription)
    }
}
