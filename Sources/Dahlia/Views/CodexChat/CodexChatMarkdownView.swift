import SwiftUI

struct CodexChatMarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                CodexChatMarkdownBlockView(block: block)
            }
        }
    }

    private var blocks: [CodexChatMarkdownBlock] {
        CodexChatMarkdownCache.blocks(for: markdown)
    }
}
