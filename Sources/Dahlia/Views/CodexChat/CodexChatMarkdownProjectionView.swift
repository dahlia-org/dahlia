import SwiftUI

struct CodexChatMarkdownProjectionView: View {
    let blocks: [CodexChatMarkdownRenderedBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            groupViews
        }
    }

    private var groupViews: some View {
        let groups = CodexChatMarkdownRenderedGroup.build(from: blocks)
        return ForEach(groups.indices, id: \.self) { index in
            switch groups[index] {
            case let .text(blocks):
                CodexChatMarkdownTextView(blocks: blocks)
            case let .code(language, text):
                CodexChatMarkdownCodeBlockView(language: language, text: text)
            }
        }
    }

}
