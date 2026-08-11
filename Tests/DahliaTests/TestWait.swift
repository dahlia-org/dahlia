import Foundation

/// Deadline shared by the polling waits in this test target.
///
/// Swift Testing starts every test at once, so the whole suite competes for a small number of
/// cores. A wait that resolves in milliseconds on a developer machine has been observed taking
/// tens of seconds on CI purely from scheduling delay. This deadline therefore sits far above the
/// time any of these waits actually needs: it exists to describe a genuine hang, not a busy
/// machine. A suite that uses it must not carry a shorter `.timeLimit` trait, because the trait
/// would fail the test before the wait reports anything useful.
let testPollTimeout = Duration.seconds(120)

/// Polls `condition` until it holds or `timeout` elapses, and reports whether it held.
///
/// Prefer this over a hand-rolled deadline loop, and never over `Task.yield()` spinning, which
/// keeps the caller's executor busy for the whole wait. Inheriting `#isolation` lets `@MainActor`
/// suites and non-isolated suites share one implementation.
func pollUntil(
    timeout: Duration = testPollTimeout,
    interval: Duration = .milliseconds(10),
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline, !Task.isCancelled {
        if await condition() { return true }
        try? await Task.sleep(for: interval)
    }
    return await condition()
}
