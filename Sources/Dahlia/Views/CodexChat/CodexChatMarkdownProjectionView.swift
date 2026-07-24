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
                blockViews
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                blockViews
            }
        }
    }

    private var blockViews: some View {
        ForEach(blocks.indices, id: \.self) { index in
            CodexChatMarkdownBlockView(block: block(at: index))
        }
    }

    private func block(at index: Int) -> CodexChatMarkdownRenderedBlock {
        guard index == blocks.indices.last,
              let pendingSuffix
        else { return blocks[index] }

        return blocks[index].appendingPendingSuffix(pendingSuffix) ?? blocks[index]
    }
}
