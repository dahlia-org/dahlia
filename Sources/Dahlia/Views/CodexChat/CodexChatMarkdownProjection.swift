struct CodexChatMarkdownProjection: Sendable {
    let markdown: String
    let blocks: [CodexChatMarkdownRenderedBlock]
}
