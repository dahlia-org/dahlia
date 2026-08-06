import Foundation
import os

private final class SpeakerDiarizationProcessingTask: Sendable {
    private struct State {
        var task: Task<SpeakerDiarizationOutput, any Error>?
        var isCancelled = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func start(
        operation: @escaping @Sendable () async throws -> SpeakerDiarizationOutput,
        makeTask: SerialDiarizerHost.ProcessingTaskFactory
    ) -> Task<SpeakerDiarizationOutput, any Error> {
        state.withLock { state in
            let task = makeTask {
                try Task.checkCancellation()
                return try await operation()
            }
            state.task = task
            if state.isCancelled {
                task.cancel()
            }
            return task
        }
    }

    func cancel() {
        let task = state.withLock { state in
            state.isCancelled = true
            return state.task
        }
        task?.cancel()
    }
}

extension SerialDiarizerHost {
    static func processRequest(
        _ request: Request,
        operation: @escaping @Sendable (Request) async throws -> SpeakerDiarizationOutput,
        makeTask: ProcessingTaskFactory = { operation in
            Task { try await operation() }
        }
    ) async -> Result<SpeakerDiarizationOutput, any Error>? {
        let processing = SpeakerDiarizationProcessingTask()
        guard request.ticket.installCancellation({ processing.cancel() }) else { return nil }
        let task = processing.start(operation: {
            try await operation(request)
        }, makeTask: makeTask)
        let result: Result<SpeakerDiarizationOutput, any Error>
        do {
            result = try await withTaskCancellationHandler {
                try await .success(task.value)
            } onCancel: {
                processing.cancel()
            }
        } catch {
            result = .failure(error)
        }
        return result
    }
}

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
