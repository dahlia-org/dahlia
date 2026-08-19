import SwiftUI

struct CodexChatMeetingReferenceBadge: View {
    let name: String

    var body: some View {
        Label(name, systemImage: "calendar")
            .font(.caption2)
            .lineLimit(1)
            .frame(maxWidth: 240, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                .background.opacity(0.72),
                in: RoundedRectangle(cornerRadius: DahliaDesign.Highlight.compactCornerRadius)
            )
            .overlay {
                RoundedRectangle(cornerRadius: DahliaDesign.Highlight.compactCornerRadius)
                    .stroke(.separator, lineWidth: 1)
            }
            .contentShape(.rect)
            .accessibilityElement(children: .combine)
    }
}
