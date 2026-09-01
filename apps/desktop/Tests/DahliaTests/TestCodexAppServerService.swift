import Foundation
@testable import Dahlia

/// Builds a `CodexAppServerService` for tests that exercise protocol ordering, cancellation, and
/// failure handling rather than the transport deadline itself.
///
/// Production uses `transportTimeout: .seconds(15)`. Swift Testing starts every test at once, so a
/// loaded runner can delay a stubbed exchange past that deadline and report `.requestTimedOut` in
/// place of the behavior under test. Tests that do assert timeout behavior pass an explicit
/// per-request `timeout:` or inject a clock, so the long default here does not weaken them.
func makeTestCodexAppServerService(
    transportFactory: @escaping CodexAppServerService.TransportFactory,
    clock: any CodexAppServerClock = ContinuousCodexAppServerClock(),
    summaryTimeout: Duration = .seconds(270),
    providerAuthenticationPreparation: @escaping CodexAppServerService.ProviderAuthenticationPreparation = { _, _ in false },
    configurationReadiness: @escaping CodexAppServerService.ConfigurationReadiness = { true },
    accountProviderResolver: @escaping CodexAppServerService.AccountProviderResolver = { nil },
    runtimeProviderResolver: @escaping CodexAppServerService.RuntimeProviderResolver = { .chatGPTSubscription }
) -> CodexAppServerService {
    CodexAppServerService(
        transportFactory: transportFactory,
        clock: clock,
        transportTimeout: .seconds(600),
        summaryTimeout: summaryTimeout,
        providerAuthenticationPreparation: providerAuthenticationPreparation,
        configurationReadiness: configurationReadiness,
        accountProviderResolver: accountProviderResolver,
        runtimeProviderResolver: runtimeProviderResolver
    )
}
