import Foundation

protocol CodexAppServerClock: Sendable {
    func sleep(for duration: Duration) async throws
}

struct ContinuousCodexAppServerClock: CodexAppServerClock {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
