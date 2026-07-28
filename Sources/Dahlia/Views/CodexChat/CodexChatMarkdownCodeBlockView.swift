import SwiftUI

struct CodexChatMarkdownCodeBlockView: View {
    let language: String?
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let language {
                Text(language)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
