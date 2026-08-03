import Foundation

actor CodexChatMarkdownRenderer: CodexChatMarkdownRendering {
    private let cache: CodexChatMarkdownCache
    private var previousParsedBlocks: [CodexChatMarkdownBlock] = []
    private var previousRenderedBlocks: [CodexChatMarkdownRenderedBlock] = []

    init(cache: CodexChatMarkdownCache = .shared) {
        self.cache = cache
    }

    func blocks(
        for markdown: String,
        cacheResult: Bool
    ) async throws -> CodexChatMarkdownRenderResult {
        try Task.checkCancellation()
        if cacheResult, let result = await cache.result(for: markdown) {
            return result
        }

        let parsed = try CodexChatMarkdownParser.parseTrackingUnstableTail(markdown)
        let blocks = try renderReusingStablePrefix(parsed.blocks)
        let result = CodexChatMarkdownRenderResult(
            blocks: blocks,
            stablePrefixBlockCount: parsed.stablePrefixBlockCount,
            reparseSource: parsed.reparseSource
        )
        if cacheResult {
            await cache.insert(result, for: markdown)
        }
        return result
    }

    nonisolated func pendingBlocks(
        reparseSource: String,
        suffix: String
    ) async throws -> [CodexChatMarkdownRenderedBlock] {
        try Task.checkCancellation()
        let blocks = try CodexChatMarkdownParser.parse(reparseSource + suffix)
        return try CodexChatMarkdownBlockRenderer.render(blocks)
    }

    func cache(
        _ result: CodexChatMarkdownRenderResult,
        for markdown: String
    ) async {
        await cache.insert(result, for: markdown)
    }

    private func renderReusingStablePrefix(
        _ parsedBlocks: [CodexChatMarkdownBlock]
    ) throws -> [CodexChatMarkdownRenderedBlock] {
        let reusableCount = zip(previousParsedBlocks, parsedBlocks)
            .prefix(while: { $0.0 == $0.1 })
            .count
        var renderedBlocks = Array(previousRenderedBlocks.prefix(reusableCount))
        renderedBlocks.reserveCapacity(parsedBlocks.count)
        for block in parsedBlocks.dropFirst(reusableCount) {
            try Task.checkCancellation()
            try renderedBlocks.append(CodexChatMarkdownBlockRenderer.render(block))
        }
        previousParsedBlocks = parsedBlocks
        previousRenderedBlocks = renderedBlocks
        return renderedBlocks
    }

}
