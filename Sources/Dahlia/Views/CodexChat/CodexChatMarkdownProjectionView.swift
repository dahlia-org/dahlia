import SwiftUI

struct CodexChatMarkdownProjectionView: View {
    let blocks: [CodexChatMarkdownRenderedBlock]
    let pendingSuffix: String?

    init(
        blocks: [CodexChatMarkdownRenderedBlock],
        pendingSuffix: String? = nil
    ) {
        self.blocks = blocks
        self.pendingSuffix = pendingSuffix
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            groupViews
        }
    }

    private var groupViews: some View {
        let groups = CodexChatMarkdownRenderedGroup.build(from: displayedBlocks)
        return ForEach(groups.indices, id: \.self) { index in
            switch groups[index] {
            case let .text(blocks):
                CodexChatMarkdownTextView(blocks: blocks)
            case let .code(language, text):
                CodexChatMarkdownCodeBlockView(language: language, text: text)
            }
        }
    }

    private var displayedBlocks: [CodexChatMarkdownRenderedBlock] {
        guard let lastIndex = blocks.indices.last,
              let pendingSuffix,
              let lastBlock = blocks[lastIndex].appendingPendingSuffix(pendingSuffix)
        else { return blocks }

        var displayedBlocks = blocks
        displayedBlocks[lastIndex] = lastBlock
        return displayedBlocks
    }
}
