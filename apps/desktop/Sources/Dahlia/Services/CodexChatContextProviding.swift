import Foundation

@MainActor
protocol CodexChatContextProviding: AnyObject {
    func currentContext(workspaceID: UUID) async throws -> CodexChatContext?
}
