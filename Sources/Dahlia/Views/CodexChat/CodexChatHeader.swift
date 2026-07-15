import SwiftUI

struct CodexChatHeader: View {
    let title: String
    let showsHistory: Bool
    let hasConversation: Bool
    let allowsPopOut: Bool
    let onBack: () -> Void
    let onShowHistory: () -> Void
    let onNewChat: () -> Void
    let onPopOut: () -> Void
    let onHide: () -> Void
    var onDragChanged: ((CGSize) -> Void)?
    var onDragEnded: ((CGSize) -> Void)?

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
            if allowsPopOut {
                CodexChatIconButton(
                    label: L10n.popOutChat,
                    systemImage: "rectangle.on.rectangle",
                    action: onPopOut
                )
            }
            CodexChatIconButton(label: L10n.hideChat, systemImage: "minus", action: onHide)
        }
        .padding(.horizontal, CodexChatDesign.headerHorizontalPadding)
        .frame(height: CodexChatDesign.headerHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { onDragChanged?($0.translation) }
                .onEnded { onDragEnded?($0.translation) },
            isEnabled: onDragChanged != nil
        )
    }

}
