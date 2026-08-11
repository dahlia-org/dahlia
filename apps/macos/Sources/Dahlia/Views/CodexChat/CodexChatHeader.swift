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
    let onHide: (() -> Void)?
    var onDragChanged: ((CGSize) -> Void)?
    var onDragEnded: ((CGSize) -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if showsHistory {
                CodexChatIconButton(label: L10n.back, systemImage: "chevron.left", action: onBack)
                Text(L10n.chatHistory)
                    .font(.body)
                    .gesture(headerDragGesture, isEnabled: onDragChanged != nil)
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
                    .gesture(headerDragGesture, isEnabled: onDragChanged != nil)
            }

            Spacer(minLength: 8)
                .contentShape(Rectangle())
                .gesture(headerDragGesture, isEnabled: onDragChanged != nil)

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
            if let onHide {
                CodexChatIconButton(label: L10n.hideChat, systemImage: "minus", action: onHide)
            }
        }
        .padding(.horizontal, CodexChatDesign.headerHorizontalPadding)
        .frame(height: CodexChatDesign.headerHeight)
    }

    private var headerDragGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { onDragChanged?($0.translation) }
            .onEnded { onDragEnded?($0.translation) }
    }
}
