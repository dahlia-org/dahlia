import Foundation

struct ChatItemPage: Sendable {
    let items: [ChatItem]
    let nextCursor: String?
}
