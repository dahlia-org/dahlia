import Foundation

enum CodexChatTurnEvent: Equatable {
    case started(turnID: String)
    case delta(itemID: String, text: String)
    case completed(itemID: String?, text: String?)
    case reasoningDelta(itemID: String, summaryIndex: Int, text: String)
    case reasoningCompleted(itemID: String, text: String)
    case interrupted
    case failed(message: String?)

    var terminalCompletion: Bool? {
        switch self {
        case .completed(itemID: nil, text: _):
            true
        case .interrupted, .failed:
            false
        default:
            nil
        }
    }
}
