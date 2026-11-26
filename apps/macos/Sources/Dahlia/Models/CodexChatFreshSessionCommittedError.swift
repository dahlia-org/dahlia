import Foundation

/// Startup failed after the durable reset boundary; retry must keep that session rather than reset it again.
struct CodexChatFreshSessionCommittedError: LocalizedError {
    let underlyingError: any Error

    var errorDescription: String? { underlyingError.localizedDescription }
}
