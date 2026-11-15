import Foundation

/// A disposable projection. Overflow detaches only the slow reader; the service still owns and saves the run.
struct ChatTurnBroadcast {
    struct ReaderOverflow: Error {}

    typealias Continuation = AsyncThrowingStream<CodexChatTurnEvent, any Error>.Continuation
    var readers: [UUID: Continuation] = [:]
    var text = ""
    var reasoning = ""
    var itemID: String?
    var activity: CodexChatToolActivity?
    var approvals: [String: CodexChatApprovalRequest] = [:]

    mutating func yield(_ event: CodexChatTurnEvent) {
        switch event {
        case let .delta(id, delta): itemID = id
            text += delta
        case let .reasoningDelta(id, _, delta): itemID = id
            reasoning += delta
        case .completed(itemID: .some, text: _): text = ""
            reasoning = ""
            itemID = nil
        case let .toolActivity(value): activity = value
        case let .approvalRequested(value): approvals[value.id] = value
        case let .approvalResolved(id): approvals[id] = nil
        default: break
        }
        for (id, reader) in readers {
            switch reader.yield(event) {
            case .dropped:
                reader.finish(throwing: ReaderOverflow())
                readers[id] = nil
            case .terminated: readers[id] = nil
            case .enqueued: break
            @unknown default: break
            }
        }
    }

    func finish(throwing error: (any Error)? = nil) {
        for reader in readers.values {
            reader.finish(throwing: error)
        }
    }
}
