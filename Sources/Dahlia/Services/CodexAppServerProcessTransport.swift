import Darwin
import Dispatch
import Foundation
import os

/// Process stdio adapter. All potentially blocking pipe operations stay outside Swift's cooperative executor.
actor CodexAppServerProcessTransport: CodexAppServerTransport {
    private enum OutputTermination: Sendable {
        case overflow
        case end(Int32)
    }

    // DispatchIO reads as fast as the child writes, so the bytes waiting to reach the actor need
    // their own ceiling. Without one the documented maximumBufferedOutputLines policy only applies
    // after parsing, which leaves memory growth unbounded ahead of it.
    private static let maximumBufferedOutputChunks = 64
    private static let maximumOutputChunkBytes = 64 * 1024

    private let process: Process
    private let inputChannel: DispatchIO
    private let outputChannel: DispatchIO
    private let errorChannel: DispatchIO
    private let ioQueue = DispatchQueue(label: "app.dahlia.codex-app-server-stdio")
    private var isOutputDrainStarted = false
    private var isErrorDrainStarted = false
    private var isErrorDrainFinished = false
    private var stdoutPending = Data()
    private var outputLines: [Data] = []
    private var outputLineReadIndex = 0
    private var outputWaiter: (id: UUID, continuation: CheckedContinuation<Data?, any Error>)?
    private var outputError: (any Error)?
    private var didReachOutputEOF = false
    private var pendingWrites: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var isClosed = false
    private var stderrTail = Data()
    private let maximumBufferedOutputLines = 1024
    private let minimumConsumedOutputLinesBeforeCompaction = 256
    #if DEBUG
        private var outputBufferOverflowWaiters: [CheckedContinuation<Void, Never>] = []
    #endif

    init(
        executableURL: URL,
        arguments: [String] = ["app-server"],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil
    ) throws {
        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        process.currentDirectoryURL = currentDirectoryURL
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            throw CodexAppServerError.launchFailed(error.localizedDescription)
        }

        let inputHandle = standardInput.fileHandleForWriting
        let duplicatedInput = Darwin.dup(inputHandle.fileDescriptor)
        guard duplicatedInput >= 0 else {
            process.terminate()
            throw CodexAppServerError.launchFailed(String(cString: strerror(errno)))
        }
        let outputHandle = standardOutput.fileHandleForReading
        let duplicatedOutput = Darwin.dup(outputHandle.fileDescriptor)
        guard duplicatedOutput >= 0 else {
            Darwin.close(duplicatedInput)
            process.terminate()
            throw CodexAppServerError.launchFailed(String(cString: strerror(errno)))
        }
        let errorHandle = standardError.fileHandleForReading
        let duplicatedError = Darwin.dup(errorHandle.fileDescriptor)
        guard duplicatedError >= 0 else {
            Darwin.close(duplicatedOutput)
            Darwin.close(duplicatedInput)
            process.terminate()
            throw CodexAppServerError.launchFailed(String(cString: strerror(errno)))
        }
        try? inputHandle.close()
        try? outputHandle.close()
        try? errorHandle.close()

        self.process = process
        inputChannel = DispatchIO(type: .stream, fileDescriptor: duplicatedInput, queue: ioQueue) { _ in
            Darwin.close(duplicatedInput)
        }
        outputChannel = DispatchIO(type: .stream, fileDescriptor: duplicatedOutput, queue: ioQueue) { _ in
            Darwin.close(duplicatedOutput)
        }
        errorChannel = DispatchIO(type: .stream, fileDescriptor: duplicatedError, queue: ioQueue) { _ in
            Darwin.close(duplicatedError)
        }
        // A JSON-RPC line must reach the reader as soon as the child writes it, and one delivery
        // must stay small enough that the handoff ceiling below is expressed in bytes, not chunks.
        outputChannel.setLimit(lowWater: 1)
        outputChannel.setLimit(highWater: Self.maximumOutputChunkBytes)
        errorChannel.setLimit(highWater: 4096)
    }

    func sendLine(_ data: Data) async throws {
        guard !isClosed else { throw CodexAppServerError.processExited(stderrDescription) }
        startDrainsIfNeeded()
        var line = data
        line.append(0x0A)
        let writeID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let dispatchData = line.withUnsafeBytes { DispatchData(bytes: $0) }
                pendingWrites[writeID] = continuation
                inputChannel.write(offset: 0, data: dispatchData, queue: ioQueue) { [weak self] done, data, errorCode in
                    guard done else { return }
                    Task {
                        await self?.completeWrite(
                            writeID,
                            errorCode: errorCode,
                            hasRemainingData: !(data?.isEmpty ?? true)
                        )
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelWrite(writeID) }
        }
    }

    func receiveLine() async throws -> Data? {
        startDrainsIfNeeded()
        if let line = dequeueOutputLine() {
            return line
        }
        if let outputError { throw outputError }
        if isClosed || didReachOutputEOF { return nil }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if outputWaiter != nil {
                    continuation.resume(throwing: CodexAppServerError.invalidProtocolResponse)
                } else {
                    outputWaiter = (waiterID, continuation)
                }
            }
        } onCancel: {
            Task { await self.cancelOutputWaiter(waiterID) }
        }
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true

        let writes = pendingWrites.values
        pendingWrites.removeAll()
        for continuation in writes {
            continuation.resume(throwing: CancellationError())
        }

        inputChannel.close(flags: .stop)
        await waitForExit(for: .seconds(1))
        if process.isRunning {
            process.terminate()
            await waitForExit(for: .seconds(1))
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            await waitForExit(for: .seconds(1))
        }

        outputChannel.close(flags: .stop)
        errorChannel.close(flags: .stop)
        outputWaiter?.continuation.resume(returning: nil)
        outputWaiter = nil
    }

    #if DEBUG
        func processIdentifierForTesting() -> pid_t {
            process.processIdentifier
        }

        func waitUntilOutputBufferOverflowForTesting() async {
            startDrainsIfNeeded()
            if outputError as? CodexAppServerError == .outputBufferOverflow { return }
            await withCheckedContinuation { continuation in
                outputBufferOverflowWaiters.append(continuation)
            }
        }

        func enqueueOutputLinesForTesting(_ lines: [Data]) {
            for line in lines {
                enqueueOutputLine(line)
            }
        }

        func outputBufferStateForTesting() -> (unreadLineCount: Int, retainedByteCount: Int) {
            (
                outputLines.count - outputLineReadIndex,
                outputLines.reduce(into: 0) { $0 += $1.count }
            )
        }
    #endif

    private var stderrDescription: String? {
        String(data: stderrTail, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }

    private func appendStderr(_ data: Data) {
        stderrTail.append(data)
        let maximumBytes = 16 * 1024
        if stderrTail.count > maximumBytes {
            stderrTail.removeFirst(stderrTail.count - maximumBytes)
        }
    }

    private func startDrainsIfNeeded() {
        // A closed transport has already released its channels. Restarting a drain here would
        // read from a torn-down descriptor instead of reporting the closure to the caller.
        guard !isClosed else { return }
        startOutputDrainIfNeeded()
        startErrorDrainIfNeeded()
    }

    private func startOutputDrainIfNeeded() {
        guard !isOutputDrainStarted else { return }
        isOutputDrainStarted = true
        let (chunks, continuation) = AsyncStream<Data>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.maximumBufferedOutputChunks)
        )
        // The terminal outcome must not compete with chunks for stream capacity. Yielding it into a
        // full buffer would drop it, ending the consumer without ever reporting EOF or overflow and
        // leaving the reader suspended in receiveLine. First writer wins, so a later callback on the
        // stopped channel cannot relabel an overflow as a clean exit.
        let termination = OSAllocatedUnfairLock<OutputTermination?>(initialState: nil)
        // DispatchIO keeps the blocking pipe read on ioQueue. The stream carries chunks into the
        // actor in arrival order, which one unstructured task per chunk would not guarantee.
        outputChannel.read(offset: 0, length: Int.max, queue: ioQueue) { done, data, errorCode in
            if let data, !data.isEmpty {
                // Losing even one chunk splices unrelated bytes into the next line, so a full
                // buffer becomes the documented overflow rather than a silent discard.
                if case .dropped = continuation.yield(Data(data)) {
                    termination.withLock { $0 = $0 ?? .overflow }
                    continuation.finish()
                    return
                }
            }
            if done {
                termination.withLock { $0 = $0 ?? .end(errorCode) }
                continuation.finish()
            }
        }
        Task { [weak self] in
            for await chunk in chunks {
                await self?.consumeStdout(chunk)
            }
            // Runs after every buffered chunk has been parsed, so a trailing partial line is still
            // whole by the time the terminal outcome is applied.
            switch termination.withLock({ $0 }) {
            case .overflow:
                await self?.failOutputDrainWithOverflow()
            case let .end(errorCode):
                await self?.finishOutputDrain(errorCode: errorCode)
            case nil:
                break
            }
        }
    }

    private func startErrorDrainIfNeeded() {
        guard !isErrorDrainStarted else { return }
        isErrorDrainStarted = true
        errorChannel.read(offset: 0, length: Int.max, queue: ioQueue) { [weak self] done, data, _ in
            let chunk = data.map { Data($0) } ?? Data()
            Task {
                await self?.consumeStderr(chunk, done: done)
            }
        }
    }

    private func consumeStdout(_ data: Data) {
        stdoutPending.append(data)
        guard stdoutPending.contains(0x0A) else { return }
        var lines = stdoutPending.split(separator: 0x0A, omittingEmptySubsequences: false)
        stdoutPending = Data(lines.removeLast())
        for line in lines where !line.isEmpty {
            enqueueOutputLine(Data(line))
        }
    }

    private func failOutputDrainWithOverflow() {
        // Continuing to read only discards more bytes, and the buffered prefix can no longer be
        // parsed into whole lines.
        outputChannel.close(flags: .stop)
        stdoutPending.removeAll()
        latchOutputBufferOverflow()
        guard let waiter = outputWaiter else { return }
        outputWaiter = nil
        waiter.continuation.resume(throwing: CodexAppServerError.outputBufferOverflow)
    }

    private func latchOutputBufferOverflow() {
        outputLines.removeAll(keepingCapacity: false)
        outputLineReadIndex = 0
        outputError = CodexAppServerError.outputBufferOverflow
        #if DEBUG
            let waiters = outputBufferOverflowWaiters
            outputBufferOverflowWaiters.removeAll()
            waiters.forEach { $0.resume() }
        #endif
    }

    private func finishOutputDrain(errorCode: Int32) async {
        // The child may exit after a final line that carries no trailing newline.
        if !stdoutPending.isEmpty {
            let trailing = stdoutPending
            stdoutPending.removeAll()
            enqueueOutputLine(trailing)
        }
        guard errorCode != 0 else {
            await finishOutput()
            return
        }
        await finishOutput(throwing: NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errorCode),
            userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errorCode))]
        ))
    }

    private func consumeStderr(_ data: Data, done: Bool) {
        if !data.isEmpty {
            appendStderr(data)
        }
        if done {
            isErrorDrainFinished = true
        }
    }

    private func enqueueOutputLine(_ line: Data) {
        if let waiter = outputWaiter {
            outputWaiter = nil
            waiter.continuation.resume(returning: line)
        } else {
            guard outputError == nil else { return }
            if outputLines.count - outputLineReadIndex >= maximumBufferedOutputLines {
                latchOutputBufferOverflow()
                return
            }
            outputLines.append(line)
        }
    }

    private func dequeueOutputLine() -> Data? {
        guard outputLineReadIndex < outputLines.count else { return nil }
        let line = outputLines[outputLineReadIndex]
        // Release the payload now; the empty prefix is compacted less frequently.
        outputLines[outputLineReadIndex] = Data()
        outputLineReadIndex += 1
        if outputLineReadIndex == outputLines.count {
            outputLines.removeAll(keepingCapacity: true)
            outputLineReadIndex = 0
        } else if outputLineReadIndex >= minimumConsumedOutputLinesBeforeCompaction,
                  outputLineReadIndex * 2 >= outputLines.count {
            outputLines.removeFirst(outputLineReadIndex)
            outputLineReadIndex = 0
        }
        return line
    }

    private func finishOutput(throwing error: (any Error)? = nil) async {
        for _ in 0 ..< 20 where !isErrorDrainFinished {
            try? await Task.sleep(for: .milliseconds(5))
        }
        didReachOutputEOF = true
        if !isClosed, outputError == nil {
            outputError = CodexAppServerError.processExited(
                stderrDescription ?? error?.localizedDescription
            )
        }
        guard let waiter = outputWaiter else { return }
        outputWaiter = nil
        if let outputError {
            waiter.continuation.resume(throwing: outputError)
        } else {
            waiter.continuation.resume(returning: nil)
        }
    }

    private func cancelOutputWaiter(_ waiterID: UUID) {
        guard outputWaiter?.id == waiterID else { return }
        let waiter = outputWaiter
        outputWaiter = nil
        waiter?.continuation.resume(throwing: CancellationError())
    }

    private func completeWrite(_ writeID: UUID, errorCode: Int32, hasRemainingData: Bool) {
        guard let continuation = pendingWrites.removeValue(forKey: writeID) else { return }
        if errorCode == 0, !hasRemainingData, !isClosed {
            continuation.resume()
        } else {
            continuation.resume(throwing: CodexAppServerError.processExited(stderrDescription))
        }
    }

    private func cancelWrite(_ writeID: UUID) {
        pendingWrites.removeValue(forKey: writeID)?.resume(throwing: CancellationError())
    }

    private func waitForExit(for duration: Duration) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: duration)
        while process.isRunning, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
