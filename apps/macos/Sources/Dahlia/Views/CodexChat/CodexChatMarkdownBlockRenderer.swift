import Foundation

enum CodexChatMarkdownBlockRenderer {
    static func render(
        _ blocks: [CodexChatMarkdownBlock]
    ) throws -> [CodexChatMarkdownRenderedBlock] {
        var renderedBlocks: [CodexChatMarkdownRenderedBlock] = []
        renderedBlocks.reserveCapacity(blocks.count)
        for block in blocks {
            try Task.checkCancellation()
            try renderedBlocks.append(render(block))
        }
        return renderedBlocks
    }

    static func render(_ block: CodexChatMarkdownBlock) throws -> CodexChatMarkdownRenderedBlock {
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
        case let .table(table):
            try .table(CodexChatMarkdownRenderedTable(
                header: table.header.map { value in
                    try Task.checkCancellation()
                    return attributedMarkdown(value)
                },
                rows: table.rows.map { row in
                    try Task.checkCancellation()
                    return try row.map { value in
                        try Task.checkCancellation()
                        return attributedMarkdown(value)
                    }
                },
                alignments: table.alignments
            ))
        case let .code(language, text):
            .code(language: language, text: text)
        case .divider:
            .divider
        }
    }

    private static func attributedMarkdown(_ value: String) -> AttributedString {
        (try? AttributedString(
            markdown: value,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(value)
    }
}
