import SwiftUI

struct CodexChatHeader: View {
    let title: String
    let showsHistory: Bool
    let hasConversation: Bool
    let onBack: () -> Void
    let onNewChat: () -> Void
    let onShowFullScreen: (() -> Void)?
    let reservesSidebarToggle: Bool
    let reservesWindowControls: Bool
    let leadingInset: CGFloat
    var showsTitle = true
    var parentTitle: String?
    var onOpenParent: (() -> Void)?
    /// An agent's thread reads `Agents / <its icon and name>` instead of `Dahlia AI / <title>`.
    var agent: AgentRecord?
    /// A thread of the agent other than its conversation, such as an intake thread, adds ` / <title>`.
    var agentThreadTitle: String?
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

            if showsTitle, let agent {
                HStack(spacing: 8) {
                    Text(L10n.agentBots)
                        .fixedSize()
                    Text("/")
                        .foregroundStyle(DahliaDesign.secondaryTextColor)
                        .accessibilityHidden(true)
                    AgentAvatarView(avatar: agent.avatar, color: agent.color, size: DahliaTypography.size(offset: 4))
                    Text(agent.name)
                        .lineLimit(1)
                        .layoutPriority(-1)
                    if let agentThreadTitle {
                        Text("/")
                            .foregroundStyle(DahliaDesign.secondaryTextColor)
                            .accessibilityHidden(true)
                        Text(agentThreadTitle)
                            .foregroundStyle(DahliaDesign.secondaryTextColor)
                            .lineLimit(1)
                            .layoutPriority(-1)
                    }
                }
                .font(.dahliaBody)
                .foregroundStyle(DahliaDesign.primaryTextColor)
            } else if showsTitle {
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

            if !showsHistory, hasConversation {
                DahliaWindowHeaderIconButton(
                    label: L10n.newChat,
                    systemImage: "plus.message",
                    action: onNewChat
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
