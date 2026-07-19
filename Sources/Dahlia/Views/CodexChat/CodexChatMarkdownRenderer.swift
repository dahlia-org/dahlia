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
    ) async throws -> [CodexChatMarkdownRenderedBlock] {
        try Task.checkCancellation()
        if cacheResult, let blocks = await cache.blocks(for: markdown) {
            return blocks
        }

        let parsedBlocks = try CodexChatMarkdownParser.parse(markdown)
        let blocks = try renderReusingStablePrefix(parsedBlocks)
        if cacheResult {
            await cache.insert(blocks, for: markdown)
        }
        return blocks
    }

    func cache(
        _ blocks: [CodexChatMarkdownRenderedBlock],
        for markdown: String
    ) async {
        await cache.insert(blocks, for: markdown)
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
            try renderedBlocks.append(render(block))
        }
        previousParsedBlocks = parsedBlocks
        previousRenderedBlocks = renderedBlocks
        return renderedBlocks
    }

    private func render(_ block: CodexChatMarkdownBlock) throws -> CodexChatMarkdownRenderedBlock {
        try Task.checkCancellation()
        return switch block {
        case let .paragraph(text):
            .paragraph(attributedMarkdown(text))
        case let .heading(level, text):
            .heading(level: level, text: attributedMarkdown(text))
        case let .unorderedList(items):
            try .unorderedList(items.map { item in
                try Task.checkCancellation()
                return attributedMarkdown(item)
            })
        case let .orderedList(items):
            try .orderedList(items.map { item in
                try Task.checkCancellation()
                return CodexChatMarkdownRenderedOrderedItem(
                    marker: item.marker,
                    text: attributedMarkdown(item.text)
                )
            })
        case let .blockquote(text):
            .blockquote(attributedMarkdown(text))
        case let .code(language, text):
            .code(language: language, text: text)
        case .divider:
            .divider
        }
    }

    private func attributedMarkdown(_ value: String) -> AttributedString {
        (try? AttributedString(
            markdown: value,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(value)
    }
}
