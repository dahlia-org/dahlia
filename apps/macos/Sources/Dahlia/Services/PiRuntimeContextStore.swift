import Foundation
import Synchronization

/// Whether the app's account has written Pi's configuration, so AI work can start.
final class PiRuntimeContextStore: Sendable {
    static let didChange = Notification.Name("DahliaPiRuntimeContextDidChange")
    static let shared = PiRuntimeContextStore()

    private struct State: Sendable {
        var isConfigured = false
        var isActivating = false
        var providers: [String: ProviderAccount] = [:]
        var dahliaBaseURL: URL?
    }

    struct Configuration: Sendable {
        let isConfigured: Bool
        let providers: [String: ProviderAccount]
        let dahliaBaseURL: URL?
    }

    private let state = Mutex(State())

    var isConfigured: Bool {
        state.withLock(\.isConfigured)
    }

    var configuration: Configuration {
        state.withLock { Configuration(isConfigured: $0.isConfigured, providers: $0.providers, dahliaBaseURL: $0.dahliaBaseURL) }
    }

    func beginActivation() {
        state.withLock {
            $0.isConfigured = false
            $0.isActivating = true
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func activationFailed() {
        state.withLock {
            $0.isConfigured = false
            $0.isActivating = false
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func apply(providers: [ProviderAccount] = [], dahliaBaseURL: URL? = nil) {
        let bindings = Dictionary(providers.map { ($0.piProviderID, $0) }, uniquingKeysWith: { first, _ in first })
        state.withLock {
            $0.providers = bindings
            $0.dahliaBaseURL = dahliaBaseURL
            $0.isConfigured = true
            $0.isActivating = false
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Waits while the configuration is being written; throws when it is not ready.
    func waitUntilActive() async throws {
        let changes = NotificationCenter.default.notifications(named: Self.didChange)
        try Task.checkCancellation()
        if try isActive() { return }
        for await _ in changes {
            try Task.checkCancellation()
            if try isActive() { return }
        }
        throw CancellationError()
    }

    private func isActive() throws -> Bool {
        let current = state.withLock { $0 }
        guard !current.isActivating else { return false }
        guard current.isConfigured else { throw AIConfigurationError.accountNotReady }
        return true
    }
}
