import SwiftUI

struct CodexChatErrorView: View {
    @Environment(MainWindowNavigation.self) private var mainWindowNavigation

    let message: String
    let onRetry: () -> Void
    var onSkipAndContinue: (() -> Void)?

    // shortcut: other runtime setup errors identify their page in the text; carry the error's kind here if
    // a message names Advanced Settings for another reason.
    var recoverySettingsCategory: SettingsCategory {
        if message == L10n.codexNotLoggedIn {
            .providers
        } else if message == L10n.piCommandNotFound || message.contains(L10n.agentAdvancedSettings) {
            .agents
        } else {
            .modelProvider
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.dahliaBody)
                .foregroundStyle(.red)
            HStack {
                Button(L10n.retry, action: onRetry)
                if let onSkipAndContinue {
                    Button(L10n.chatSkipAndContinue, action: onSkipAndContinue)
                }
                switch recoverySettingsCategory {
                case .providers:
                    Button(L10n.manageProviders) { mainWindowNavigation.openSettings(category: .providers) }
                case .agents:
                    Button(L10n.openAgentSettings) { mainWindowNavigation.openSettings(category: .agents) }
                default:
                    Button(L10n.openAISettings) { mainWindowNavigation.openSettings(category: .modelProvider) }
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, CodexChatDesign.contentHorizontalPadding)
        .padding(.vertical, 6)
    }
}
