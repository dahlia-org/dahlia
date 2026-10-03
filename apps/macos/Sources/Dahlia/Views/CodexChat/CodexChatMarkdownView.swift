import SwiftUI

struct CodexChatMarkdownView: View {
    let markdown: String
    let isStreaming: Bool

    @State private var projectionModel: CodexChatMarkdownProjectionModel

    init(
        markdown: String,
        isStreaming: Bool = false
    ) {
        self.markdown = markdown
        self.isStreaming = isStreaming
        _projectionModel = State(initialValue: CodexChatMarkdownProjectionModel())
    }

    var body: some View {
        Group {
            if let displayBlocks = projectionModel.displayBlocks {
                CodexChatMarkdownProjectionView(blocks: displayBlocks)
            } else {
                Text(markdown)
                    .textSelection(.enabled)
            }
        }
        .transaction { transaction in
            transaction.animation = nil
        }
        .onChange(
            of: CodexChatMarkdownInput(markdown: markdown, isStreaming: isStreaming),
            initial: true
        ) { _, input in
            projectionModel.submit(input)
        }
        .onDisappear(perform: projectionModel.cancel)
    }
}
