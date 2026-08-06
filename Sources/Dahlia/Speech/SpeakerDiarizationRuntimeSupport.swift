import Foundation
import os

final class RequestTicket: Sendable {
    private struct State {
        var continuation: CheckedContinuation<SpeakerDiarizationOutput, any Error>?
        var cancelProcessing: (@Sendable () -> Void)?
        var isCompleted = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func install(continuation: CheckedContinuation<SpeakerDiarizationOutput, any Error>) {
        let shouldCancel = state.withLock { state in
            guard !state.isCompleted else { return true }
            state.continuation = continuation
            return false
        }
        if shouldCancel {
            continuation.resume(throwing: CancellationError())
        }
    }

    var isCompleted: Bool {
        state.withLock(\.isCompleted)
    }

    func installCancellation(_ cancel: @escaping @Sendable () -> Void) -> Bool {
        let shouldRun = state.withLock { state in
            guard !state.isCompleted else { return false }
            state.cancelProcessing = cancel
            return true
        }
        if !shouldRun {
            cancel()
        }
        return shouldRun
    }

    func cancel() {
        finish(with: .failure(CancellationError()))
    }

    func complete(_ result: Result<SpeakerDiarizationOutput, any Error>) {
        finish(with: result)
    }

    private func finish(with result: Result<SpeakerDiarizationOutput, any Error>) {
        let completion = state.withLock { state -> (
            CheckedContinuation<SpeakerDiarizationOutput, any Error>?,
            (@Sendable () -> Void)?
        ) in
            guard !state.isCompleted else { return (nil, nil) }
            state.isCompleted = true
            let continuation = state.continuation
            let cancelProcessing = state.cancelProcessing
            state.continuation = nil
            state.cancelProcessing = nil
            return (continuation, cancelProcessing)
        }
        if case let .failure(error) = result, error is CancellationError {
            completion.1?()
        }
        completion.0?.resume(with: result)
    }
}
