import SwiftUI

struct CodexChatHeader: View {
    let title: String
    let showsHistory: Bool
    let hasConversation: Bool
    let onBack: () -> Void
    let onShowHistory: () -> Void
    let onNewChat: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if showsHistory {
                CodexChatIconButton(label: L10n.back, systemImage: "chevron.left", action: onBack)
                Text(L10n.chatHistory)
                    .font(.body)
            } else {
                if hasConversation {
                    CodexChatIconButton(label: L10n.newChat, systemImage: "square.and.pencil", action: onNewChat)
                    Divider()
                        .frame(height: 16)
                }
                Text(title)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if !showsHistory {
                CodexChatIconButton(
                    label: L10n.chatHistory,
                    systemImage: "clock.arrow.circlepath",
                    action: onShowHistory
                )
            }
        }
        .padding(.horizontal, CodexChatDesign.headerHorizontalPadding)
        .frame(height: CodexChatDesign.headerHeight)
    }
}
