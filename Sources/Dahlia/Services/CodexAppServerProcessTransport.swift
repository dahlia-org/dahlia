import Darwin
import Dispatch
import Foundation

/// Process stdio adapter. All potentially blocking pipe operations stay outside Swift's cooperative executor.
actor CodexAppServerProcessTransport: CodexAppServerTransport {
    private static let maximumOutputReadBytes = 64 * 1024
    private static let maximumOutputLineBytes = 4 * 1024 * 1024

    private let process: Process
    private let inputChannel: DispatchIO
    private let outputChannel: DispatchIO
    private let errorChannel: DispatchIO
    private let ioQueue = DispatchQueue(label: "app.dahlia.codex-app-server-stdio")
    private var activeOutputReadID: UUID?
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
    private let minimumConsumedOutputLinesBeforeCompaction = 256
    #if DEBUG
        private var outputReadTestGate: CodexAppServerOutputReadTestGate?
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
        // Deliver short JSON-RPC lines promptly while keeping each read window byte-bounded.
        outputChannel.setLimit(lowWater: 1)
        outputChannel.setLimit(highWater: Self.maximumOutputReadBytes)
        errorChannel.setLimit(highWater: 4096)
    }

    func sendLine(_ data: Data) async throws {
        guard !isClosed else { throw CodexAppServerError.processExited(stderrDescription) }
        startErrorDrainIfNeeded()
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
        startErrorDrainIfNeeded()
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
                    startOutputReadIfNeeded()
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

        func setOutputReadTestGateForTesting(_ gate: CodexAppServerOutputReadTestGate) {
            outputReadTestGate = gate
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

    private func startOutputReadIfNeeded() {
        guard !isClosed, !didReachOutputEOF, outputError == nil,
              outputWaiter != nil, activeOutputReadID == nil else { return }
        let readID = UUID()
        let relay = CodexOutputReadRelay()
        activeOutputReadID = readID
        #if DEBUG
            let testGate = outputReadTestGate
            testGate?.recordReadStarted()
        #endif
        outputChannel.read(
            offset: 0,
            length: Self.maximumOutputReadBytes,
            queue: ioQueue
        ) { done, data, errorCode in
            relay.append(data.map { Data($0) } ?? Data(), done: done, errorCode: errorCode)
            #if DEBUG
                if done {
                    testGate?.recordReadFinished(retainedByteCount: relay.retainedByteCount())
                }
            #endif
        }
        Task { [weak self] in
            await self?.consumeOutputRead(readID: readID, relay: relay)
        }
    }

    private func startErrorDrainIfNeeded() {
        // A closed transport has already released its channels. Restarting a drain here would
        // read from a torn-down descriptor instead of reporting the closure to the caller.
        guard !isClosed, !isErrorDrainStarted else { return }
        isErrorDrainStarted = true
        errorChannel.read(offset: 0, length: Int.max, queue: ioQueue) { [weak self] done, data, _ in
            let chunk = data.map { Data($0) } ?? Data()
            Task {
                await self?.consumeStderr(chunk, done: done)
            }
        }
    }

    private func consumeOutputRead(readID: UUID, relay: CodexOutputReadRelay) async {
        #if DEBUG
            await outputReadTestGate?.waitBeforeDraining()
        #endif
        while activeOutputReadID == readID {
            let snapshot = await relay.next()
            guard activeOutputReadID == readID else { return }
            if !snapshot.data.isEmpty, !consumeStdout(snapshot.data) {
                return
            }
            guard let errorCode = snapshot.terminalErrorCode else { continue }
            activeOutputReadID = nil
            if errorCode != 0 || snapshot.totalByteCount < Self.maximumOutputReadBytes {
                await finishOutputRead(errorCode: errorCode)
            } else {
                startOutputReadIfNeeded()
            }
        }
    }

    private func consumeStdout(_ data: Data) -> Bool {
        var segmentStart = data.startIndex
        while let newline = data[segmentStart...].firstIndex(of: 0x0A) {
            let fragment = data[segmentStart ..< newline]
            guard appendToPendingLine(fragment) else { return false }
            if !stdoutPending.isEmpty {
                let line = stdoutPending
                stdoutPending = Data()
                enqueueOutputLine(line)
            }
            segmentStart = data.index(after: newline)
        }
        return appendToPendingLine(data[segmentStart...])
    }

    private func appendToPendingLine(_ fragment: Data.SubSequence) -> Bool {
        guard fragment.count <= Self.maximumOutputLineBytes - stdoutPending.count else {
            failOutputLineTooLarge()
            return false
        }
        stdoutPending.append(contentsOf: fragment)
        return true
    }

    private func failOutputLineTooLarge() {
        // The output can no longer be framed safely. Stop the shared connection without retaining
        // or reporting any portion of the line.
        let error = CodexAppServerError.outputLineTooLarge
        activeOutputReadID = nil
        outputChannel.close(flags: .stop)
        stdoutPending.removeAll(keepingCapacity: false)
        outputLines.removeAll(keepingCapacity: false)
        outputLineReadIndex = 0
        outputError = error
        guard let waiter = outputWaiter else { return }
        outputWaiter = nil
        waiter.continuation.resume(throwing: error)
    }

    private func finishOutputRead(errorCode: Int32) async {
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
