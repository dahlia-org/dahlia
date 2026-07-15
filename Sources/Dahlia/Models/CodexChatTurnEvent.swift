import Foundation

enum CodexChatTurnEvent: Equatable {
    case started(turnID: String)
    case delta(itemID: String, text: String)
    case completed(itemID: String?, text: String?)
    case interrupted
    case failed(message: String?)
}
