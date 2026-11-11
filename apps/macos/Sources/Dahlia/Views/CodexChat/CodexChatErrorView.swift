import SwiftUI

struct CodexChatErrorView: View {
    @Environment(MainWindowNavigation.self) private var mainWindowNavigation

    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.dahliaBody)
                .foregroundStyle(.red)
            HStack {
                Button(L10n.retry, action: onRetry)
                // The button opens the page the message names: Pi itself and its sign-ins are under Agents (not signed
                // in, Pi not found); other errors concern the account's model settings.
                // shortcut: matches the page's name in the text; carry the error's kind here if a message names Agents
                // for another reason.
                if message.contains(L10n.agents) {
                    Button(L10n.openAgentSettings) { mainWindowNavigation.openSettings(category: .agents) }
                } else {
                    Button(L10n.openAISettings) { mainWindowNavigation.openSettings(category: .modelProvider) }
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, CodexChatDesign.contentHorizontalPadding)
        .padding(.vertical, 6)
    }
}
