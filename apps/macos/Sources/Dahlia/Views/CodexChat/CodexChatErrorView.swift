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
                // Pi installation lives under General; provider sign-in and models live under Models.
                // shortcut: matches the page's name in the text; carry the error's kind here if a message names Agents
                // for another reason.
                if message == L10n.codexNotLoggedIn {
                    Button(L10n.openAgentSettings) { mainWindowNavigation.openAgentSettings(tab: .models) }
                } else if message.contains(L10n.agents) {
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
