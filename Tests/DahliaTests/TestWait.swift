import Foundation

/// Deadline shared by the polling waits in this test target.
///
/// Swift Testing schedules the entire target concurrently, so MainActor work can queue behind
/// synchronous database tests even when the observed operation itself resolves in milliseconds.
/// Two minutes still fails a genuine hang before the CI job timeout without treating runner
/// scheduling as failure.
let testPollTimeout = Duration.seconds(120)

/// Polls `condition` until it holds or `timeout` elapses, and reports whether it held.
///
/// Prefer this over a hand-rolled deadline loop, and never over `Task.yield()` spinning, which
/// keeps the caller's executor busy for the whole wait. Inheriting `#isolation` lets `@MainActor`
/// suites and non-isolated suites share one implementation.
func pollUntil(
    timeout: Duration = testPollTimeout,
    interval: Duration = .milliseconds(10),
    isolation _: isolated (any Actor)? = #isolation,
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline, !Task.isCancelled {
        if await condition() { return true }
        try? await Task.sleep(for: interval)
    }
    return await condition()
}
