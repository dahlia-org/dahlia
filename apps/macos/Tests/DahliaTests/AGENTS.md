# Tests/DahliaTests Guide

Tests are complete when they prove the changed behavior with reproducible inputs and run without depending on the user's environment or live external services.

## Running Tests

```bash
swift test --package-path apps/macos --filter SummaryServiceTests # Example targeted suite
swift test --package-path apps/macos                              # Full suite
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
- Await observable state or events in asynchronous tests; do not rely on fixed sleeps.
- For bug fixes, prefer a regression test that fails before the fix and passes afterward.
