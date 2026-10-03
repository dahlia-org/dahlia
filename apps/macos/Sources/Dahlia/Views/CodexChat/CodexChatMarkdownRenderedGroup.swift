enum CodexChatMarkdownRenderedGroup: Equatable, Sendable {
    case text([CodexChatMarkdownRenderedBlock])
    case code(language: String?, text: String)

    static func build(
        from blocks: [CodexChatMarkdownRenderedBlock]
    ) -> [Self] {
        var groups: [Self] = []
        var textBlocks: [CodexChatMarkdownRenderedBlock] = []

        func appendTextBlocks() {
            guard !textBlocks.isEmpty else { return }
            groups.append(.text(textBlocks))
            textBlocks.removeAll(keepingCapacity: true)
        }

        for block in blocks {
            if case let .code(language, text) = block {
                appendTextBlocks()
                groups.append(.code(language: language, text: text))
            } else {
                textBlocks.append(block)
            }
        }
        appendTextBlocks()
        return groups
    }
}
