import Foundation

/// Deadline shared by the polling waits in this test target.
///
/// Every wait in this target resolves in milliseconds once the process is healthy, so this
/// deadline exists only to describe a genuine hang. Keep it short enough that a regression fails
/// the run quickly instead of stalling CI: a test that needs longer than this is waiting on
/// something that blocks the cooperative pool or the MainActor, which is the bug to fix.
let testPollTimeout = Duration.seconds(15)

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
