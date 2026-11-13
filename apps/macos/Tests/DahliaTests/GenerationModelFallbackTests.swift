import Foundation
import Synchronization
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct GenerationModelFallbackTests {
        @Test(arguments: [nil, "", "primary"] as [String?])
        func disabledOrDuplicateFallbackDoesNotRetry(fallback: String?) async {
            let calls = Mutex<[String?]>([])
            await #expect(throws: PiRuntimeError.emptyResponse) {
                let _: String = try await GenerationModelFallback.run(model: "primary", fallbackModel: fallback) { model in
                    calls.withLock { $0.append(model) }
                    throw PiRuntimeError.emptyResponse
                }
            }
            #expect(calls.withLock { $0 } == ["primary"])
        }

        @Test
        func successfulPrimaryDoesNotUseFallback() async throws {
            let calls = Mutex<[String?]>([])
            let result = try await GenerationModelFallback.run(model: "primary", fallbackModel: "fallback") { model in
                calls.withLock { $0.append(model) }
                return "Valid output"
            }
            #expect(result == "Valid output")
            #expect(calls.withLock { $0 } == ["primary"])
        }

        @Test(arguments: [
            PiRuntimeError.emptyResponse,
            .invalidProtocolResponse,
            .turnFailed("length"),
            .requestedModelUnavailable("primary"),
            .requestTimedOut("generate"),
        ])
        func generationFailuresTryFallbackOnce(error: PiRuntimeError) async throws {
            let calls = Mutex<[String?]>([])
            let result = try await GenerationModelFallback.run(model: "primary", fallbackModel: "fallback") { model in
                calls.withLock { $0.append(model) }
                if model == "primary" { throw error }
                return "Recovered"
            }
            #expect(result == "Recovered")
            #expect(calls.withLock { $0 } == ["primary", "fallback"])
        }

        @Test
        func failingFallbackPropagatesItsErrorWithoutAnotherAttempt() async {
            let calls = Mutex<[String?]>([])
            await #expect(throws: PiRuntimeError.turnFailed("fallback failed")) {
                let _: String = try await GenerationModelFallback.run(model: "primary", fallbackModel: "fallback") { model in
                    calls.withLock { $0.append(model) }
                    if model == "primary" { throw PiRuntimeError.emptyResponse }
                    throw PiRuntimeError.turnFailed("fallback failed")
                }
            }
            #expect(calls.withLock { $0 } == ["primary", "fallback"])
        }

        @Test(arguments: [PiRuntimeError.turnInterrupted, .backendResetForSafety, .notLoggedIn, .piCommandNotFound(nil)])
        func interruptedOrUnavailableRuntimeDoesNotUseFallback(error: PiRuntimeError) async {
            let calls = Mutex<[String?]>([])
            await #expect(throws: error) {
                let _: String = try await GenerationModelFallback.run(model: "primary", fallbackModel: "fallback") { model in
                    calls.withLock { $0.append(model) }
                    throw error
                }
            }
            #expect(calls.withLock { $0 } == ["primary"])
        }

        @Test
        func cancellationAfterFailureDoesNotStartFallback() async {
            let calls = Mutex<[String?]>([])
            let task = Task {
                let _: String = try await GenerationModelFallback.run(model: "primary", fallbackModel: "fallback") { model in
                    calls.withLock { $0.append(model) }
                    withUnsafeCurrentTask { $0?.cancel() }
                    throw PiRuntimeError.emptyResponse
                }
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(calls.withLock { $0 } == ["primary"])
        }
    }
#endif
