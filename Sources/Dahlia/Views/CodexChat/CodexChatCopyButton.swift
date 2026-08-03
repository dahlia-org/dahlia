import SwiftUI

struct CodexChatCopyButton: View {
    let text: String
    var title = L10n.copyChatMessage

    var body: some View {
        Button(action: copyMessage) {
            Label(title, systemImage: "square.on.square")
                .labelStyle(.iconOnly)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.tertiary)
        .help(title)
    }

    private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
