import SwiftUI

struct CodexChatNoticeView: View {
    let text: String
    let level: CodexChatNoticeLevel

    @State private var isExpanded = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: level.symbol)
                        .accessibilityHidden(true)
                    Text(text.replacingOccurrences(of: "\n", with: " "))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.dahliaSecondary)
                        .foregroundStyle(DahliaDesign.secondaryTextColor)
                        .accessibilityHidden(true)
                }
                .padding(4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.orange)
            .background(isHovering ? DahliaDesign.contentHighlightColor : .clear, in: .rect(cornerRadius: 4))
            .onHover { isHovering = $0 }
            .accessibilityValue(isExpanded ? L10n.chatNoticeExpanded : L10n.chatNoticeCollapsed)
            .accessibilityIdentifier("chat-notice-toggle")

            if isExpanded {
                Text(text)
                    .font(.dahliaBody.monospaced())
                    .foregroundStyle(DahliaDesign.secondaryTextColor)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("chat-notice-detail")
            }
        }
        .font(.dahliaBody)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
