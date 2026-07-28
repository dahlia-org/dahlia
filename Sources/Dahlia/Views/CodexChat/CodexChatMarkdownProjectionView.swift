import SwiftUI

struct CodexChatMarkdownProjectionView: View {
    let blocks: [CodexChatMarkdownRenderedBlock]
    let pendingSuffix: String?
    let usesLazyLayout: Bool

    init(
        blocks: [CodexChatMarkdownRenderedBlock],
        pendingSuffix: String? = nil,
        usesLazyLayout: Bool = true
    ) {
        self.blocks = blocks
        self.pendingSuffix = pendingSuffix
        self.usesLazyLayout = usesLazyLayout
    }

    var body: some View {
        if usesLazyLayout {
            LazyVStack(alignment: .leading, spacing: 10) {
                groupViews
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                groupViews
            }
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
