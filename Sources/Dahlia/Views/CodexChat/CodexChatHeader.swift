import SwiftUI

struct CodexChatHeader: View {
    let title: String
    let showsHistory: Bool
    let hasConversation: Bool
    let onBack: () -> Void
    let onShowHistory: () -> Void
    let onNewChat: () -> Void
    let onPopOut: (() -> Void)?
    let reservesSidebarToggle: Bool
    let reservesWindowControls: Bool

    var body: some View {
        DahliaWindowHeader(reservesWindowControls: reservesWindowControls) {
            if showsHistory {
                DahliaWindowHeaderIconButton(
                    label: L10n.back,
                    systemImage: "chevron.left",
                    action: onBack
                )
                Text(L10n.chatHistory)
                    .font(.body)
            } else {
                if hasConversation {
                    DahliaWindowHeaderIconButton(
                        label: L10n.newChat,
                        systemImage: "square.and.pencil",
                        action: onNewChat
                    )
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
