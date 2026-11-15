import SwiftUI

struct CodexChatSendButton: View {
    @Bindable var session: CodexChatSessionModel
    @AppStorage(AppSettings.chatDeliveryModeUserDefaultsKey) private var deliveryMode: CodexChatDeliveryMode = .queue
    let isCommandPressed: Bool

    var body: some View {
        let mode = deliveryMode.resolved(commandPressed: isCommandPressed)
        if session.isGenerating, !session.hasComposerContent {
            CodexChatActionButton(
                label: L10n.stopGenerating, systemImage: "stop.fill", isEnabled: true, action: session.stop
            )
        } else {
            CodexChatActionButton(
                label: session.isGenerating ? mode.title : L10n.sendMessage,
                systemImage: session.isGenerating ? mode.symbol : "arrow.up",
                isEnabled: session.canSend,
                action: send
            )
            .help(L10n.chatFollowUpHelp)
        }
    }

    private func send() {
        session.sendDraft(commandPressed: isCommandPressed)
    }
}
