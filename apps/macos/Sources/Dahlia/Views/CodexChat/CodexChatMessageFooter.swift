import SwiftUI

struct CodexChatMessageFooter: View {
    let message: CodexChatMessage
    let text: String
    let isHovered: Bool

    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverEnabled

    var body: some View {
        HStack(spacing: 8) {
            if message.role == .user { timestamp }

            if !text.isEmpty {
                CodexChatCopyButton(
                    text: text,
                    isVisible: isHovered,
                    feedbackAlignment: message.role == .user ? .topTrailing : .topLeading
                )
            }

            if message.role == .assistant {
                Button {} label: {
                    Label(L10n.chatForkFromResponse, systemImage: "arrow.triangle.branch")
                        .labelStyle(.iconOnly)
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(true)
                .help(L10n.chatForkFromResponse)
                .opacity(isHovered || isVoiceOverEnabled ? 1 : 0)

                timestamp
            }
        }
        .font(.dahliaSecondary)
        .foregroundStyle(DahliaDesign.optionalTextColor)
    }

    @ViewBuilder
    private var timestamp: some View {
        if let timestamp = message.timestamp {
            Text(timestamp, format: .dateTime.hour().minute())
                .help(timestamp.formatted(date: .abbreviated, time: .standard))
                .opacity(isHovered || isVoiceOverEnabled ? 1 : 0)
        }
    }
}
