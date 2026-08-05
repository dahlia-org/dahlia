import Foundation

struct CodexChatApprovalFileChangeSnapshot {
    let changes: [CodexChatApprovalRequest.FileChange]
    let isTruncated: Bool
}

struct CodexChatApprovalFileChangeCache {
    static let itemLimit = 16

    private(set) var values: [String: CodexChatApprovalFileChangeSnapshot] = [:]
    private var itemOrder: [String] = []

    mutating func store(
        _ snapshot: CodexChatApprovalFileChangeSnapshot,
        for itemID: String
    ) {
        if values[itemID] == nil {
            itemOrder.append(itemID)
        }
        values[itemID] = snapshot
        while itemOrder.count > Self.itemLimit {
            values.removeValue(forKey: itemOrder.removeFirst())
        }
    }

    mutating func removeValue(forKey itemID: String) {
        values.removeValue(forKey: itemID)
        itemOrder.removeAll { $0 == itemID }
    }
}
