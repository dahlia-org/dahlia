import SwiftUI

struct CodexChatCopyButton: View {
    let text: String

    var body: some View {
        Button(L10n.copyChatMessage, systemImage: "square.on.square", action: copyMessage)
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .help(L10n.copyChatMessage)
    }

    private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
