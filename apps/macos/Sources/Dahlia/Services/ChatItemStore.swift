import DahliaRuntimeSupport
import Foundation

/// Only the append-only item log is replaceable. The thread catalog always stays in GRDB.
protocol ChatItemStore: Sendable {
    func appendItems(threadID: String, items: [JSONValue]) async throws
    func listItems(threadID: String, cursor: String?, limit: Int) async throws -> ChatItemPage
}
