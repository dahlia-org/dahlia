import Darwin
import Dispatch
import Foundation

/// Process stdio adapter. All potentially blocking pipe operations stay outside Swift's cooperative executor.
actor CodexAppServerProcessTransport: CodexAppServerTransport {
    private let process: Process
    private let inputChannel: DispatchIO
    private let outputHandle: FileHandle
    private let errorChannel: DispatchIO
    private let ioQueue = DispatchQueue(label: "app.dahlia.codex-app-server-stdio")
    private var outputDrainTask: Task<Void, Never>?
    private var isErrorDrainStarted = false
    private var isErrorDrainFinished = false
    private var outputLines: [Data] = []
    private var outputLineOffset = 0
    private var outputWaiter: (id: UUID, continuation: CheckedContinuation<Data?, any Error>)?
    private var outputError: (any Error)?
    private var didReachOutputEOF = false
    private var pendingWrites: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var isClosed = false
    private var stderrTail = Data()
    private let maximumBufferedOutputLines = 256

    init(
        executableURL: URL,
        arguments: [String] = ["app-server"],
        environment: [String: String]? = nil
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
        let errorHandle = standardError.fileHandleForReading
        let duplicatedError = Darwin.dup(errorHandle.fileDescriptor)
        guard duplicatedError >= 0 else {
            Darwin.close(duplicatedInput)
            process.terminate()
            throw CodexAppServerError.launchFailed(String(cString: strerror(errno)))
        }
        try? inputHandle.close()
        try? errorHandle.close()

        self.process = process
        outputHandle = standardOutput.fileHandleForReading
        inputChannel = DispatchIO(type: .stream, fileDescriptor: duplicatedInput, queue: ioQueue) { descriptor in
            Darwin.close(descriptor)
        }
        errorChannel = DispatchIO(type: .stream, fileDescriptor: duplicatedError, queue: ioQueue) { descriptor in
            Darwin.close(descriptor)
        }
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
        if outputLineOffset < outputLines.count {
            let line = outputLines[outputLineOffset]
            outputLineOffset += 1
            compactOutputLinesIfNeeded()
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

        try? outputHandle.close()
        errorChannel.close(flags: .stop)
        outputDrainTask?.cancel()
        outputDrainTask = nil
        outputWaiter?.continuation.resume(returning: nil)
        outputWaiter = nil
    }

    #if DEBUG
        func processIdentifierForTesting() -> pid_t {
            process.processIdentifier
        }

        func bufferedOutputLineCountForTesting() -> Int {
            outputLines.count - outputLineOffset
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
        startOutputDrainIfNeeded()
        startErrorDrainIfNeeded()
    }

    private func startOutputDrainIfNeeded() {
        guard outputDrainTask == nil else { return }
        let outputHandle = outputHandle
        // Keep the long-lived iterator off the transport actor so waiting for the next pipe byte
        // cannot prevent a later sendLine or receiveLine call from entering the actor.
        outputDrainTask = Task.detached(priority: .utility) { [weak self] in
            do {
                for try await line in outputHandle.bytes.lines where !line.isEmpty {
                    await self?.enqueueOutputLine(Data(line.utf8))
                }
                await self?.finishOutput()
            } catch is CancellationError {
                await self?.finishOutput()
            } catch {
                await self?.finishOutput(throwing: error)
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
            if outputLines.count - outputLineOffset >= maximumBufferedOutputLines {
                outputLines.removeAll(keepingCapacity: false)
                outputLineOffset = 0
                outputError = CodexAppServerError.invalidProtocolResponse
                return
            }
            outputLines.append(line)
        }
    }

    private func finishOutput(throwing error: (any Error)? = nil) async {
        didReachOutputEOF = true
        for _ in 0 ..< 20 where !isErrorDrainFinished {
            try? await Task.sleep(for: .milliseconds(5))
        }
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

    private func compactOutputLinesIfNeeded() {
        guard outputLineOffset >= 64,
              outputLineOffset * 2 >= outputLines.count
        else { return }
        outputLines.removeFirst(outputLineOffset)
        outputLineOffset = 0
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
