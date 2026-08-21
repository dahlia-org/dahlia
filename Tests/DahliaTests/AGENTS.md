# Tests/DahliaTests Guide

Tests are complete when they prove the changed behavior with reproducible inputs and run without depending on the user's environment or live external services.

## Running Tests

```bash
swift test --filter SummaryServiceTests # Example targeted suite
swift test                              # Full suite
```

Run the targeted suite first. Expand to the full suite for changes with broad effects, including shared models, database migrations, and the recording lifecycle.

## Interpreting Results

- Do not treat exit code 0 alone as success. Confirm a summary such as `Test run with N tests`; when `xcode-select` points to Command Line Tools, the build can exit successfully while running zero tests.
- If the toolchain prevents execution, report the output of `xcode-select -p` and the tests that did not run. Do not run `sudo xcode-select -s /Applications/Xcode.app` automatically because it changes system configuration; ask the user to make that switch.

## Test Conventions

- Write new tests with Swift Testing (`import Testing`, `@Test`, and `#expect`) and follow the existing pattern of wrapping the complete file in `#if canImport(Testing)`.
- Treat XCTest as legacy. Do not use it for new tests or convert existing XCTest outside the requested scope.
- Use `@testable import Dahlia` for internal APIs.
- Mark a suite's struct `@MainActor` when it exercises `@MainActor` types; do not add per-test workarounds.
- Use `AppDatabaseManager(path: ":memory:")` for database tests. Never access the user's Application Support database.
- Replace network access, live calendars, Keychain, microphone, system audio, and user settings with fakes, stubs, or temporary storage.
- Telemetry tests use a fake client or injected reporter and assert exact event names and allowlisted parameters. Never initialize a live telemetry SDK in tests.

## Test Design

- Cover relevant boundaries, failures, cancellation, and retries in addition to the happy path.
- Await the behavior's observable completion condition or expected event count. Do not use fixed sleeps, `Task.yield()`, or an unrelated actor call as a completion barrier.
- Never block `MainActor` or the test task with `DispatchSemaphore`. If a contention test needs a synchronous lock, confine it to a detached worker and await its observable state asynchronously.
- Register notification and callback observers before triggering the operation. When production code must catch an event immediately after initialization, add a regression test that posts it immediately after construction.
- Preserve event ordering when replacing an async sequence with callbacks. Cover overlapping operations such as an in-flight restore followed by disconnect.
- Treat an initial observation as baseline state when only later changes should trigger work. Test the initial value and a later change separately so delayed work cannot cancel unrelated operations.
- Use `#require` before indexing asynchronous results. A missing event should fail the test, not crash the test process.
- Keep polling deadlines bounded and assert the final state after the wait. Do not hide flakes with retries or longer timeouts.
- Tests share process-wide state and run concurrently in CI. Restore global settings and avoid assumptions that unrelated suites are idle; production observers should suppress duplicate values when repeated notifications are valid.
- When injecting a fake platform service, inject its capability providers too. A fake speech recognizer must not fall through to live Speech locale discovery, which can multiply XPC work under parallel tests.
- Test Speech coordination through injected operations. Do not construct live Speech framework objects when the test only needs to exercise Dahlia's cancellation or coalescing state.
- Measure the behavior under test, such as distinct preview revisions, instead of counting unrelated publications from process-wide observers.
- For bug fixes, prefer a regression test that fails before the fix and passes afterward.

## CI Stability

- Reproduce a flake with the smallest affected test first, then repeat it under the same parallelism as CI and finish with the full suite.
- Preserve the test count and success summary when checking CI-equivalent runs. A retry, quarantine, or removed test is not a stability fix.
- Optimize by removing unnecessary waits and duplicate work before changing parallelism, cache behavior, or polling deadlines.
