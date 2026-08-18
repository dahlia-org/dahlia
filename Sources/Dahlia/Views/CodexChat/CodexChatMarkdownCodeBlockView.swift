import SwiftUI

struct CodexChatMarkdownCodeBlockView: View {
    let language: String?
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let language {
                    Text(language)
                        .dahliaFont(.secondary)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                CodexChatCopyButton(text: text, title: L10n.copyCodeBlock)
            }
            ScrollView(.horizontal) {
                Text(text)
                    .dahliaFont(.body, design: .monospaced)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
