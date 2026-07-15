import SwiftUI

struct CodexChatErrorView: View {
    let message: String
    let canRetryTurn: Bool
    let onRetryTurn: () -> Void
    let onRetryConnection: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
            HStack {
                Button(L10n.retry, action: canRetryTurn ? onRetryTurn : onRetryConnection)
                SettingsLink { Text(L10n.openAISettings) }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, CodexChatDesign.contentHorizontalPadding)
        .padding(.vertical, 6)
    }
}
