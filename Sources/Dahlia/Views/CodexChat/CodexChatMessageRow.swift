import AppKit
import SwiftUI

struct CodexChatMessageRow: View {
    let message: CodexChatMessage

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user {
                Spacer(minLength: 72)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if message.text.isEmpty, message.isStreaming {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        CodexChatMarkdownView(markdown: message.text)
                    }

                    if !message.text.isEmpty, !message.isStreaming {
                        Button(L10n.copyChatMessage, systemImage: "document.on.document", action: copyMessage)
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .foregroundStyle(.tertiary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                            .help(L10n.copyChatMessage)
                    }
                }
                Spacer(minLength: 40)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
    }
}
