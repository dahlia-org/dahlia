import Foundation
import Synchronization

final class CodexRuntimeContextStore: Sendable {
    static let didChange = Notification.Name("DahliaCodexRuntimeContextDidChange")
    static let shared = CodexRuntimeContextStore()

    private struct State: Sendable {
        var provider = CodexRuntimeProvider.local
        var requestedProvider: CodexRuntimeProvider?
        var isConfigured = false
        var isActivating = false
        /// Accounts removed while the app runs. Work captured for one fails instead of waiting for it to return.
        var removedProviders: Set<CodexRuntimeProvider> = []
    }

    private let state = Mutex(State())

    var provider: CodexRuntimeProvider {
        state.withLock(\.provider)
    }

    var isConfigured: Bool {
        state.withLock(\.isConfigured)
    }

    /// The account being activated or active; set before an account switch closes the old account's processes.
    var requestedProvider: CodexRuntimeProvider? {
        state.withLock(\.requestedProvider)
    }

    func beginActivation(_ provider: CodexRuntimeProvider) {
        state.withLock {
            $0.requestedProvider = provider
            $0.isConfigured = false
            $0.isActivating = true
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func accountRemoved(_ provider: CodexRuntimeProvider) {
        state.withLock { _ = $0.removedProviders.insert(provider) }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func activationFailed() {
        state.withLock {
            $0.isConfigured = false
            $0.isActivating = false
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func apply(_ provider: CodexRuntimeProvider) {
        state.withLock {
            $0.provider = provider
            $0.requestedProvider = provider
            $0.isConfigured = true
            $0.isActivating = false
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func waitUntilActive(_ expected: CodexRuntimeProvider) async throws {
        let changes = NotificationCenter.default.notifications(named: Self.didChange)
        try Task.checkCancellation()
        if try isActive(expected) { return }
        for await _ in changes {
            try Task.checkCancellation()
            if try isActive(expected) { return }
        }
        throw CancellationError()
    }

    private func isActive(_ expected: CodexRuntimeProvider) throws -> Bool {
        let current = state.withLock { $0 }
        if current.removedProviders.contains(expected) { throw CodexConfigurationError.providerChanged(expected.displayName) }
        guard current.requestedProvider == expected else { return false }
        guard !current.isActivating else { return false }
        guard current.isConfigured, current.provider == expected else { throw CodexConfigurationError.accountNotReady }
        return true
    }
}
