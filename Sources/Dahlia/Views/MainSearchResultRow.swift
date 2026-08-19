import SwiftUI

struct MainSearchResultRow: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .dahliaFixedSymbol()
                    .foregroundStyle(DahliaDesign.secondaryTextColor)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.body)
                            .foregroundStyle(DahliaDesign.secondaryTextColor)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 12)
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
