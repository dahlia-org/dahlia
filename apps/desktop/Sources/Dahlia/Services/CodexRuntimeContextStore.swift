import Synchronization

final class CodexRuntimeContextStore: Sendable {
    static let shared = CodexRuntimeContextStore()

    private struct State: Sendable {
        var provider = CodexRuntimeProvider.chatGPTSubscription
        var isConfigured = false
    }

    private let state = Mutex(State())

    var provider: CodexRuntimeProvider {
        state.withLock(\.provider)
    }

    var isConfigured: Bool {
        state.withLock(\.isConfigured)
    }

    func apply(_ provider: CodexRuntimeProvider) {
        state.withLock {
            $0.provider = provider
            $0.isConfigured = true
        }
    }
}
