import SwiftUI

struct CodexChatMarkdownView: View {
    let markdown: String
    let isStreaming: Bool
    let usesLazyLayout: Bool

    @State private var projectionModel: CodexChatMarkdownProjectionModel

    init(
        markdown: String,
        isStreaming: Bool = false,
        usesLazyLayout: Bool = true
    ) {
        self.markdown = markdown
        self.isStreaming = isStreaming
        self.usesLazyLayout = usesLazyLayout
        _projectionModel = State(initialValue: CodexChatMarkdownProjectionModel())
    }

    var body: some View {
        Group {
            if let projection = projectionModel.projection,
               projectionModel.canDisplayProjection,
               projectionModel.canDisplayPendingSuffix {
                CodexChatMarkdownProjectionView(
                    blocks: projection.blocks,
                    pendingSuffix: projectionModel.pendingSuffix,
                    usesLazyLayout: usesLazyLayout
                )
            } else {
                Text(markdown)
                    .textSelection(.enabled)
            }
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
