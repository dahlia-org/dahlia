struct CodexChatMarkdownProjection: Equatable, Sendable {
    let markdown: String
    let blocks: [CodexChatMarkdownRenderedBlock]
    let stablePrefixBlockCount: Int
    let reparseSource: String

    var renderResult: CodexChatMarkdownRenderResult {
        CodexChatMarkdownRenderResult(
            blocks: blocks,
            stablePrefixBlockCount: stablePrefixBlockCount,
            reparseSource: reparseSource
        )
    }
}
