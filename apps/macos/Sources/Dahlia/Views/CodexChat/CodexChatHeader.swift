import SwiftUI

struct CodexChatHeader: View {
    let title: String
    let showsHistory: Bool
    let hasConversation: Bool
    let onBack: () -> Void
    let onShowHistory: () -> Void
    let onNewChat: () -> Void
    let onShowFullScreen: (() -> Void)?
    let onPopOut: (() -> Void)?
    let reservesSidebarToggle: Bool
    let reservesWindowControls: Bool
    let leadingInset: CGFloat

    var body: some View {
        DahliaWindowHeader(reservesWindowControls: reservesWindowControls) {
            if leadingInset > 0 {
                Color.clear
                    .frame(width: leadingInset - DahliaDesign.windowHeaderGroupSpacing)
                    .accessibilityHidden(true)
            }

            if showsHistory {
                DahliaWindowHeaderIconButton(
                    label: L10n.back,
                    systemImage: "chevron.left",
                    action: onBack
                )
            }

            HStack(spacing: 8) {
                Image(systemName: "message")
                    .dahliaFixedSymbol()
                    .accessibilityHidden(true)
                Text(L10n.dahliaAI)
                    .fixedSize()
            }
            .font(.dahliaBody)
            .foregroundStyle(DahliaDesign.primaryTextColor)

            if showsHistory || hasConversation {
                Text("/")
                    .foregroundStyle(DahliaDesign.secondaryTextColor)
                    .accessibilityHidden(true)
                Text(showsHistory ? L10n.chatHistory : title)
                    .font(.dahliaBody)
                    .foregroundStyle(DahliaDesign.secondaryTextColor)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }

            Spacer(minLength: 8)

            if !showsHistory {
                if hasConversation {
                    DahliaWindowHeaderIconButton(
                        label: L10n.newChat,
                        systemImage: "plus.message",
                        action: onNewChat
                    )
                }
                DahliaWindowHeaderIconButton(
                    label: L10n.chatHistory,
                    systemImage: "clock.arrow.circlepath",
                    action: onShowHistory
                )
            }

            if let onPopOut {
                DahliaWindowHeaderIconButton(
                    label: L10n.popOutChat,
                    systemImage: "rectangle.on.rectangle",
                    action: onPopOut
                )
            }

            if let onShowFullScreen {
                DahliaWindowHeaderIconButton(
                    label: L10n.showChatFullScreen,
                    systemImage: "arrow.up.left.and.arrow.down.right",
                    action: onShowFullScreen
                )
            }

            if reservesSidebarToggle {
                Color.clear
                    .frame(
                        width: DahliaDesign.windowHeaderControlSize,
                        height: DahliaDesign.windowHeaderControlSize
                    )
                    .accessibilityHidden(true)
            }
        }
    }
}
