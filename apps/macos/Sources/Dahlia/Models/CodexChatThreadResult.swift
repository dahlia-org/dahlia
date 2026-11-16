import Foundation

/// A notification keeps the result of one run even when its thread starts another run.
struct CodexChatThreadResult: Identifiable, Equatable {
    let id: String
    let thread: CodexChatThreadSummary
}
