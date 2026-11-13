import Foundation

enum GenerationModelFallback {
    static func run<Value: Sendable>(
        model: String?,
        fallbackModel: String?,
        operation: @Sendable (String?) async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        do {
            return try await operation(model)
        } catch {
            try Task.checkCancellation()
            guard let fallbackModel, !fallbackModel.isEmpty, fallbackModel != model,
                  allowsFallback(after: error) else { throw error }
            return try await operation(fallbackModel)
        }
    }

    private static func allowsFallback(after error: any Error) -> Bool {
        switch error {
        case PiRuntimeError.emptyResponse, PiRuntimeError.invalidProtocolResponse,
             PiRuntimeError.turnFailed, PiRuntimeError.requestedModelUnavailable,
             PiRuntimeError.requestTimedOut, PiRuntimeError.processExited,
             PiRuntimeError.rpcError, PiRuntimeError.providerAuthenticationFailed,
             ScreenshotAnalysisError.invalidResponse:
            true
        default:
            false
        }
    }
}
