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
        let projection = projectionModel.projection
        let showsProjection = projection != nil
            && projectionModel.canDisplayProjection
            && projectionModel.canDisplayPendingSuffix
        let pendingSuffix: String? = if projectionModel.canDisplayPendingSuffix {
            projectionModel.pendingSuffix
        } else {
            nil
        }

        ZStack(alignment: .topLeading) {
            Text(markdown)
                .textSelection(.enabled)
                .opacity(showsProjection ? 0 : 1)
                .frame(height: showsProjection ? 0 : nil, alignment: .top)
                .clipped()
                .allowsHitTesting(!showsProjection)
                .accessibilityHidden(showsProjection)

            if let projection {
                CodexChatMarkdownProjectionView(
                    blocks: projection.blocks,
                    pendingSuffix: pendingSuffix,
                    usesLazyLayout: usesLazyLayout
                )
                .opacity(showsProjection ? 1 : 0)
                .frame(height: showsProjection ? nil : 0, alignment: .top)
                .clipped()
                .allowsHitTesting(showsProjection)
                .accessibilityHidden(!showsProjection)
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
