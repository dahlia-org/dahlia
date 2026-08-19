import SwiftUI

struct MainSearchResultRow: View {
    let title: String
    var inlineDetail: String?
    var projectBadge: String?
    var projectTint: Color?
    var dateText: String?
    var shortcutNumber: Int?
    var leadingProjectAppearance: ProjectAppearance?
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let leadingProjectAppearance {
                    ProjectAppearanceIcon(appearance: leadingProjectAppearance)
                }

                Text(title)
                    .lineLimit(1)

                if let inlineDetail, !inlineDetail.isEmpty {
                    Text(inlineDetail)
                        .font(.subheadline)
                        .foregroundStyle(DahliaDesign.secondaryTextColor)
                        .lineLimit(1)
                }

                if let projectBadge, !projectBadge.isEmpty {
                    Text(projectBadge)
                        .font(.caption2)
                        .foregroundStyle(DahliaDesign.secondaryTextColor)
                        .lineLimit(1)
                        .dahliaChipSurface(tint: projectTint)
                        .layoutPriority(1)
                }

                Spacer(minLength: 8)

                if let dateText {
                    Text(dateText)
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(DahliaDesign.secondaryTextColor)
                        .fixedSize()
                }

                if dateText != nil {
                    Text(shortcutNumber.map { "⌘\($0)" } ?? "⌘9")
                        .font(.caption)
                        .monospaced()
                        .foregroundStyle(DahliaDesign.secondaryTextColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .opacity(shortcutNumber == nil ? 0 : 1)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(.rect)
            .background(
                backgroundColor,
                in: .rect(corners: .concentric(
                    minimum: .fixed(MainSearchDesign.rowCornerRadius)
                ))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var backgroundColor: Color {
        isSelected || isHovered ? DahliaDesign.contentHighlightColor : .clear
    }
}
