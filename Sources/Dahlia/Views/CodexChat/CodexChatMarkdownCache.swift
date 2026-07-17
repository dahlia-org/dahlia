@MainActor
enum CodexChatMarkdownCache {
    private static let capacity = 32
    private static var blocksByMarkdown: [String: [CodexChatMarkdownBlock]] = [:]
    private static var insertionOrder: [String] = []

    static func blocks(for markdown: String) -> [CodexChatMarkdownBlock] {
        if let blocks = blocksByMarkdown[markdown] {
            return blocks
        }

        let blocks = CodexChatMarkdownParser.parse(markdown)
        if insertionOrder.count == capacity, let oldest = insertionOrder.first {
            blocksByMarkdown.removeValue(forKey: oldest)
            insertionOrder.removeFirst()
        }
        blocksByMarkdown[markdown] = blocks
        insertionOrder.append(markdown)
        return blocks
    }
}
