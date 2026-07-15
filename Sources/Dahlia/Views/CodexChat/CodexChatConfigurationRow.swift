import SwiftUI

struct CodexChatConfigurationRow: View {
    let title: String
    let isSelected: Bool
    var trailingSystemImage: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 4)

                if isSelected || trailingSystemImage != nil {
                    Image(systemName: trailingSystemImage ?? "checkmark")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isHovering || isSelected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .onHover { isHovering = $0 }
        .accessibilityValue(isSelected ? L10n.selected : "")
    }
}
