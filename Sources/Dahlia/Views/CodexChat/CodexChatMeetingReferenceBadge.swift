import SwiftUI

struct CodexChatMeetingReferenceBadge: View {
    let name: String

    var body: some View {
        Label(name, systemImage: "calendar")
            .lineLimit(1)
            .frame(maxWidth: 240, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.separator, lineWidth: 1)
            }
            .contentShape(.rect)
            .accessibilityElement(children: .combine)
    }
}
