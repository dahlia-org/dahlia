import Foundation
@testable import Dahlia

#if canImport(Testing)
    @MainActor
    final class TestCodexChatContextProvider: CodexChatContextProviding {
        var context: CodexChatContext?
        var error: PiRuntimeError?
        var requestCount = 0
        private var shouldBlock: Bool
        private var continuation: CheckedContinuation<Void, Never>?

        init(
            context: CodexChatContext? = nil,
            error: PiRuntimeError? = nil,
            shouldBlock: Bool = false
        ) {
            self.context = context
            self.error = error
            self.shouldBlock = shouldBlock
        }

        func currentContext(workspaceID _: UUID) async throws -> CodexChatContext? {
            requestCount += 1
            if shouldBlock {
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                }
            }
            if let error {
                throw error
            }
            return context
        }

        func resume() {
            shouldBlock = false
            continuation?.resume()
            continuation = nil
        }

        func block() {
            shouldBlock = true
        }
    }
#endif
