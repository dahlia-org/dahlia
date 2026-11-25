import SwiftUI

struct CodexChatPanelToggle {
    let isShown: Bool
    let action: () -> Void
}

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
    var showsTitle = true
    var parentTitle: String?
    var onOpenParent: (() -> Void)?
    /// Opens and closes a panel beside the conversation, such as Dahlia Bot's.
    var panelToggle: CodexChatPanelToggle?
    @State private var isParentHovered = false

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

            if showsTitle {
                HStack(spacing: 8) {
                    Image(systemName: "message")
                        .dahliaFixedSymbol()
                        .accessibilityHidden(true)
                    Text(L10n.dahliaAI)
                        .fixedSize()
                }
                .font(.dahliaBody)
                .foregroundStyle(DahliaDesign.primaryTextColor)

                if showsHistory || hasConversation || parentTitle != nil {
                    if !showsHistory, let parentTitle, let onOpenParent {
                        Text("/")
                            .foregroundStyle(DahliaDesign.secondaryTextColor)
                            .accessibilityHidden(true)
                        Button(action: onOpenParent) {
                            Text(parentTitle)
                                .font(.dahliaBody)
                                .lineLimit(1)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 3)
                                .contentShape(.rect)
                                .background(isParentHovered ? DahliaDesign.contentHighlightColor : .clear, in: .rect(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .onHover { isParentHovered = $0 }
                        .layoutPriority(-1)
                    }
                    Text("/")
                        .foregroundStyle(DahliaDesign.secondaryTextColor)
                        .accessibilityHidden(true)
                    Text(showsHistory ? L10n.chatHistory : title)
                        .font(.dahliaBody)
                        .foregroundStyle(DahliaDesign.secondaryTextColor)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
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

            if let panelToggle {
                DahliaWindowHeaderIconButton(
                    label: panelToggle.isShown ? L10n.agentBotHidePanel : L10n.agentBotShowPanel,
                    systemImage: "sidebar.right",
                    action: panelToggle.action
                )
                .accessibilityValue(panelToggle.isShown ? L10n.shown : L10n.hidden)
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
