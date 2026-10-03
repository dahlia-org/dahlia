actor CodexChatMarkdownCache {
    static let shared = CodexChatMarkdownCache()

    private let capacity: Int
    private let maximumCost: Int
    private var resultsByMarkdown: [String: CodexChatMarkdownRenderResult] = [:]
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

    func result(for markdown: String) -> CodexChatMarkdownRenderResult? {
        resultsByMarkdown[markdown]
    }

    func insert(
        _ result: CodexChatMarkdownRenderResult,
        for markdown: String
    ) {
        guard resultsByMarkdown[markdown] == nil,
              capacity > 0,
              maximumCost > 0
        else { return }

        let cost = markdown.utf8.count
        guard cost <= maximumCost else { return }

        while insertionOrder.count >= capacity || totalCost + cost > maximumCost {
            guard let oldest = insertionOrder.first else { break }
            resultsByMarkdown.removeValue(forKey: oldest)
            totalCost -= costsByMarkdown.removeValue(forKey: oldest) ?? 0
            insertionOrder.removeFirst()
        }

        resultsByMarkdown[markdown] = result
        costsByMarkdown[markdown] = cost
        insertionOrder.append(markdown)
        totalCost += cost
    }

    func cachedEntryCount() -> Int {
        resultsByMarkdown.count
    }

    func cachedCost() -> Int {
        totalCost
    }
}
