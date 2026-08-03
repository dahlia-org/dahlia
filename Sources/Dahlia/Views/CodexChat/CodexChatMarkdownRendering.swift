protocol CodexChatMarkdownRendering: Sendable {
    func blocks(
        for markdown: String,
        cacheResult: Bool
    ) async throws -> CodexChatMarkdownRenderResult

    func pendingBlocks(
        reparseSource: String,
        suffix: String
    ) async throws -> [CodexChatMarkdownRenderedBlock]

    func cache(
        _ result: CodexChatMarkdownRenderResult,
        for markdown: String
    ) async
}
