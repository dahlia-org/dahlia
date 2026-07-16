import Foundation

@MainActor
protocol CodexChatContextProviding: AnyObject {
    func currentContext(vaultID: UUID) async throws -> CodexChatContext?
}
