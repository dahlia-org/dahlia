struct CodexChatMarkdownRenderResult: Equatable, Sendable {
    let blocks: [CodexChatMarkdownRenderedBlock]
    let stablePrefixBlockCount: Int
    let reparseSource: String
}
