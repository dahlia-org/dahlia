import Foundation
import os

struct CodexOutputReadSnapshot: Sendable {
    let data: Data
    let terminalErrorCode: Int32?
    let totalByteCount: Int
}

/// A byte-bounded handoff for one DispatchIO read window.
///
/// DispatchIO may deliver a 64 KiB read in many small callbacks. The relay keeps one consumer
/// suspended between callbacks instead of creating a task or applying a count limit per callback.
final class CodexOutputReadRelay: Sendable {
    private struct State {
        var data = Data()
        var totalByteCount = 0
        var terminalErrorCode: Int32?
        var waiter: CheckedContinuation<CodexOutputReadSnapshot, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func append(_ data: Data, done: Bool, errorCode: Int32) {
        let delivery = state.withLock { state -> (
            CheckedContinuation<CodexOutputReadSnapshot, Never>,
            CodexOutputReadSnapshot
        )? in
            state.data.append(data)
            state.totalByteCount += data.count
            if done {
                state.terminalErrorCode = errorCode
            }
            guard let waiter = state.waiter else { return nil }
            state.waiter = nil
            return (waiter, Self.takeSnapshot(from: &state))
        }
        if let delivery {
            delivery.0.resume(returning: delivery.1)
        }
    }

    func next() async -> CodexOutputReadSnapshot {
        await withCheckedContinuation { continuation in
            let snapshot = state.withLock { state -> CodexOutputReadSnapshot? in
                if !state.data.isEmpty || state.terminalErrorCode != nil {
                    return Self.takeSnapshot(from: &state)
                }
                precondition(state.waiter == nil)
                state.waiter = continuation
                return nil
            }
            if let snapshot {
                continuation.resume(returning: snapshot)
            }
        }
    }

    #if DEBUG
        func retainedByteCount() -> Int {
            state.withLock { $0.data.count }
        }
    #endif

    private static func takeSnapshot(from state: inout State) -> CodexOutputReadSnapshot {
        let snapshot = CodexOutputReadSnapshot(
            data: state.data,
            terminalErrorCode: state.terminalErrorCode,
            totalByteCount: state.totalByteCount
        )
        state.data = Data()
        state.terminalErrorCode = nil
        return snapshot
    }
}

#if DEBUG
    /// Suspends the actor-side drain so tests can observe a completely filled read window.
    final class CodexAppServerOutputReadTestGate: Sendable {
        private struct State {
            var isReleased = false
            var didStartRead = false
            var finishedReadByteCount: Int?
            var drainWaiter: CheckedContinuation<Void, Never>?
            var readStartWaiter: CheckedContinuation<Void, Never>?
            var readFinishedWaiter: CheckedContinuation<Int, Never>?
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        func waitBeforeDraining() async {
            await withCheckedContinuation { continuation in
                let shouldResume = state.withLock { state in
                    if state.isReleased { return true }
                    precondition(state.drainWaiter == nil)
                    state.drainWaiter = continuation
                    return false
                }
                if shouldResume {
                    continuation.resume()
                }
            }
        }

        func recordReadFinished(retainedByteCount: Int) {
            let waiter = state.withLock { state -> CheckedContinuation<Int, Never>? in
                state.finishedReadByteCount = retainedByteCount
                let waiter = state.readFinishedWaiter
                state.readFinishedWaiter = nil
                return waiter
            }
            waiter?.resume(returning: retainedByteCount)
        }

        func recordReadStarted() {
            let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
                state.didStartRead = true
                let waiter = state.readStartWaiter
                state.readStartWaiter = nil
                return waiter
            }
            waiter?.resume()
        }

        func waitUntilReadStarted() async {
            await withCheckedContinuation { continuation in
                let shouldResume = state.withLock { state in
                    if state.didStartRead { return true }
                    precondition(state.readStartWaiter == nil)
                    state.readStartWaiter = continuation
                    return false
                }
                if shouldResume {
                    continuation.resume()
                }
            }
        }

        func waitUntilReadFinished() async -> Int {
            await withCheckedContinuation { continuation in
                let retainedByteCount = state.withLock { state -> Int? in
                    if let retainedByteCount = state.finishedReadByteCount {
                        return retainedByteCount
                    }
                    precondition(state.readFinishedWaiter == nil)
                    state.readFinishedWaiter = continuation
                    return nil
                }
                if let retainedByteCount {
                    continuation.resume(returning: retainedByteCount)
                }
            }
        }

        func resumeDraining() {
            let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
                state.isReleased = true
                let waiter = state.drainWaiter
                state.drainWaiter = nil
                return waiter
            }
            waiter?.resume()
        }
    }
#endif
