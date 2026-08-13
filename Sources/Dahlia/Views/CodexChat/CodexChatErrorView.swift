import SwiftUI

struct CodexChatErrorView: View {
    @Environment(MainWindowNavigation.self) private var mainWindowNavigation

    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
            HStack {
                Button(L10n.retry, action: onRetry)
                Button(L10n.openAISettings) {
                    mainWindowNavigation.openSettings(category: .modelProvider)
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, CodexChatDesign.contentHorizontalPadding)
        .padding(.vertical, 6)
    }
}
