protocol CodexChatMarkdownRendering: Sendable {
    func blocks(
        for markdown: String,
        cacheResult: Bool
    ) async throws -> [CodexChatMarkdownRenderedBlock]

    func cache(
        _ blocks: [CodexChatMarkdownRenderedBlock],
        for markdown: String
    ) async
}
