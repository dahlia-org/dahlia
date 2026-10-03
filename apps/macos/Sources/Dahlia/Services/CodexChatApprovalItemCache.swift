struct CodexChatApprovalItemCache<Value> {
    private static var itemLimit: Int { 16 }

    private(set) var values: [String: Value] = [:]
    private var itemOrder: [String] = []

    mutating func store(_ value: Value, for itemID: String) {
        if values[itemID] == nil {
            itemOrder.append(itemID)
        }
        values[itemID] = value
        while itemOrder.count > Self.itemLimit {
            values.removeValue(forKey: itemOrder.removeFirst())
        }
    }

    mutating func removeValue(forKey itemID: String) {
        values.removeValue(forKey: itemID)
        itemOrder.removeAll { $0 == itemID }
    }
}
