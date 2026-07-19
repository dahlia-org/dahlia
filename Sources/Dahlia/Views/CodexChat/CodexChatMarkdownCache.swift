actor CodexChatMarkdownCache {
    static let shared = CodexChatMarkdownCache()

    private let capacity: Int
    private let maximumCost: Int
    private var blocksByMarkdown: [String: [CodexChatMarkdownRenderedBlock]] = [:]
    private var costsByMarkdown: [String: Int] = [:]
    private var insertionOrder: [String] = []
    private var totalCost = 0

    init(
        capacity: Int = 32,
        maximumCost: Int = 512 * 1024
    ) {
        self.capacity = capacity
        self.maximumCost = maximumCost
    }

    func blocks(for markdown: String) -> [CodexChatMarkdownRenderedBlock]? {
        blocksByMarkdown[markdown]
    }

    func insert(
        _ blocks: [CodexChatMarkdownRenderedBlock],
        for markdown: String
    ) {
        guard blocksByMarkdown[markdown] == nil,
              capacity > 0,
              maximumCost > 0
        else { return }

        let cost = markdown.utf8.count
        guard cost <= maximumCost else { return }

        while insertionOrder.count >= capacity || totalCost + cost > maximumCost {
            guard let oldest = insertionOrder.first else { break }
            blocksByMarkdown.removeValue(forKey: oldest)
            totalCost -= costsByMarkdown.removeValue(forKey: oldest) ?? 0
            insertionOrder.removeFirst()
        }

        blocksByMarkdown[markdown] = blocks
        costsByMarkdown[markdown] = cost
        insertionOrder.append(markdown)
        totalCost += cost
    }

    func cachedEntryCount() -> Int {
        blocksByMarkdown.count
    }

    func cachedCost() -> Int {
        totalCost
    }
}
