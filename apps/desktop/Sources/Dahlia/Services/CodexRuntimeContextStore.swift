import Foundation
import Synchronization

final class CodexRuntimeContextStore: Sendable {
    static let didChange = Notification.Name("DahliaCodexRuntimeContextDidChange")
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
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func waitUntilActive(_ expected: CodexRuntimeProvider) async throws {
        let changes = NotificationCenter.default.notifications(named: Self.didChange)
        if isConfigured, provider == expected { return }
        for await _ in changes {
            try Task.checkCancellation()
            if isConfigured, provider == expected { return }
        }
        throw CancellationError()
    }
}
