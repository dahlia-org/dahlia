import SwiftUI

struct CodexChatCopyButton: View {
    let text: String

    var body: some View {
        Button(action: copyMessage) {
            Label(L10n.copyChatMessage, systemImage: "square.on.square")
                .labelStyle(.iconOnly)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.tertiary)
        .help(L10n.copyChatMessage)
    }

    private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
