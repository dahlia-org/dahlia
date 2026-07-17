@preconcurrency import AVFoundation
import Darwin
import Foundation
import os

actor SegmentedAudioSourceWriter {
    struct BacklogSnapshot: Equatable {
        let segmentCount: Int
        let pendingByteCount: Int64
        let oldestFinalizationStartedAt: Date?
    }

    enum Event {
        case finalizationDelayed(source: RecordingAudioSource)
        case finalizationRecovered(source: RecordingAudioSource)
        case failed(source: RecordingAudioSource, error: RecordingAudioStoreError)
    }

    typealias EventHandler = @Sendable (Event) -> Void

    private struct AudioChunk {
        let data: Data
        let frameCount: AVAudioFrameCount
    }

    private struct CallbackState {
        var acceptedFrameCount: Int64 = 0
        var error: RecordingAudioStoreError?
        var isAcceptingBuffers = true
    }

    private final class PhysicalSegment {
        let record: RecordingAudioSegmentRecord
        private(set) var frameCount: Int64 = 0
        private var audioFile: AVAudioFile?

        init(creation: RecordingAudioStore.SegmentCreation, format: AVAudioFormat) throws {
            record = creation.record
            let descriptor = open(
                creation.partialURL.path,
                O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
            guard descriptor >= 0 else {
                throw RecordingAudioStoreError.storageUnavailable
            }
            guard fchmod(descriptor, mode_t(0o600)) == 0 else {
                Darwin.close(descriptor)
                throw RecordingAudioStoreError.storageUnavailable
            }
            Darwin.close(descriptor)
            audioFile = try AVAudioFile(
                forWriting: creation.partialURL,
                settings: format.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: false
            )
        }

        func write(_ chunk: AudioChunk, format: AVAudioFormat) throws {
            guard let audioFile,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk.frameCount),
                  let channelData = buffer.int16ChannelData else {
                throw RecordingAudioStoreError.storageUnavailable
            }
            chunk.data.copyBytes(
                to: UnsafeMutableRawBufferPointer(start: channelData[0], count: chunk.data.count)
            )
            buffer.frameLength = chunk.frameCount
            try audioFile.write(from: buffer)
            frameCount += Int64(chunk.frameCount)
        }

        func close() {
            audioFile = nil
        }
    }

    private struct BoundaryWaiter {
        let targetFrame: Int64
        let continuation: CheckedContinuation<RecordingAudioRangeBoundary?, Never>
    }

    // SwiftFormat and the fallback SwiftLint modifier order disagree for nonisolated stored properties.
    // swiftlint:disable modifier_order
    private nonisolated let continuation: AsyncStream<AudioChunk>.Continuation
    private nonisolated let callbackState = OSAllocatedUnfairLock(initialState: CallbackState())
    // swiftlint:enable modifier_order

    nonisolated let source: RecordingAudioSource
    nonisolated let format: AVAudioFormat

    private let stream: AsyncStream<AudioChunk>
    private let store: RecordingAudioStore
    private let meetingId: UUID
    private let sessionId: UUID
    private let requiredSource: Bool
    private let eventHandler: EventHandler
    private var currentLocaleIdentifier: String
    private var nextSegmentIndex: Int
    private var current: PhysicalSegment?
    private var writerTask: Task<Void, Never>?
    private var finalizerTask: Task<Void, Never>?
    private var pendingFinalizationCount = 0
    private var pendingFinalizationByteCount: Int64 = 0
    private var oldestFinalizationStartedAt: Date?
    private var totalProcessedFrameCount: Int64 = 0
    private var boundaryWaiters: [BoundaryWaiter] = []
    private var pendingBoundaryCommitCount = 0
    private var boundaryCommitWaiter: CheckedContinuation<Void, Never>?
    private var isConsuming = false
    private var finalizationIsDelayed = false
    private var writeError: RecordingAudioStoreError?

    nonisolated var acceptedFrameCount: Int64 {
        callbackState.withLock(\.acceptedFrameCount)
    }

    init(
        source: RecordingAudioSource,
        format: AVAudioFormat,
        store: RecordingAudioStore,
        meetingId: UUID,
        sessionId: UUID,
        locale: Locale,
        firstSegmentIndex: Int,
        requiredSource: Bool,
        eventHandler: @escaping EventHandler
    ) {
        let pair = AsyncStream.makeStream(
            of: AudioChunk.self,
            bufferingPolicy: .bufferingOldest(256)
        )
        stream = pair.stream
        continuation = pair.continuation
        self.source = source
        self.format = format
        self.store = store
        self.meetingId = meetingId
        self.sessionId = sessionId
        self.currentLocaleIdentifier = locale.identifier
        self.nextSegmentIndex = firstSegmentIndex
        self.requiredSource = requiredSource
        self.eventHandler = eventHandler
    }

    func start(sessionOffsetSeconds: TimeInterval) async throws {
        guard current == nil else { return }
        current = try await createPhysicalSegment(sessionOffsetSeconds: sessionOffsetSeconds)
        writerTask = Task { [weak self, stream] in
            for await chunk in stream {
                await self?.consume(chunk)
            }
        }
    }

    nonisolated func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        guard buffer.format.commonFormat == .pcmFormatInt16,
              buffer.format.channelCount == 1,
              let channelData = buffer.int16ChannelData else {
            failCallback(.storageUnavailable)
            return
        }
        let frameCount = buffer.frameLength
        guard frameCount > 0 else { return }
        let data = Data(
            bytes: channelData[0],
            count: Int(frameCount) * MemoryLayout<Int16>.size
        )
        callbackState.withLock { state in
            guard state.isAcceptingBuffers else { return }
            switch continuation.yield(AudioChunk(data: data, frameCount: frameCount)) {
            case .enqueued:
                state.acceptedFrameCount += Int64(frameCount)
            case .dropped, .terminated:
                state.error = .writeQueueOverflow
                state.isAcceptingBuffers = false
            @unknown default:
                state.error = .writeQueueOverflow
                state.isAcceptingBuffers = false
            }
        }
    }

    @discardableResult
    nonisolated func seal() -> Int64 {
        callbackState.withLock { state in
            state.isAcceptingBuffers = false
            return state.acceptedFrameCount
        }
    }

    func captureLocaleBoundary() async -> RecordingAudioRangeBoundary? {
        guard writeError == nil else { return nil }
        let targetFrame = acceptedFrameCount
        if totalProcessedFrameCount >= targetFrame,
           !isConsuming || pendingBoundaryCommitCount > 0 {
            guard let boundary = currentBoundary() else { return nil }
            pendingBoundaryCommitCount += 1
            return boundary
        }
        return await withCheckedContinuation { continuation in
            boundaryWaiters.append(BoundaryWaiter(targetFrame: targetFrame, continuation: continuation))
        }
    }

    func commitLocale(_ locale: Locale) {
        currentLocaleIdentifier = locale.identifier
        completeBoundaryCommit()
    }

    func cancelLocaleBoundary() {
        completeBoundaryCommit()
    }

    func backlogSnapshot() -> BacklogSnapshot {
        BacklogSnapshot(
            segmentCount: pendingFinalizationCount,
            pendingByteCount: pendingFinalizationByteCount,
            oldestFinalizationStartedAt: oldestFinalizationStartedAt
        )
    }

    func finish() async throws {
        seal()
        resumeAllBoundaryWaiters(returning: nil)
        cancelAllBoundaryCommits()
        continuation.finish()
        await writerTask?.value
        writerTask = nil

        if let callbackError = callbackState.withLock(\.error) {
            writeError = writeError ?? callbackError
        }
        if let current {
            self.current = nil
            do {
                try await sealAndEnqueueFinalization(current)
            } catch {
                recordFailure(error)
            }
        }
        await finalizerTask?.value
        finalizerTask = nil
        try await store.markSourceEnded(sessionId: sessionId, source: source)
        if let writeError {
            throw writeError
        }
    }

    private func consume(_ chunk: AudioChunk) async {
        await waitForBoundaryCommits()
        guard writeError == nil else { return }
        isConsuming = true
        defer { isConsuming = false }
        do {
            try await rotateIfNeeded()
            guard let current else { throw RecordingAudioStoreError.invalidState }
            try await store.ensureAvailableCapacityIfNeeded(sessionId: sessionId, source: source)
            try current.write(chunk, format: format)
            totalProcessedFrameCount += Int64(chunk.frameCount)
            let resumedBoundary = resumeBoundaryWaitersIfNeeded()
            try enforceActiveSafetyBudget(current)
            if resumedBoundary {
                await waitForBoundaryCommits()
            }
        } catch {
            recordFailure(error)
        }
    }

    private func rotateIfNeeded() async throws {
        guard let current else { throw RecordingAudioStoreError.invalidState }
        let targetSeconds = Self.seconds(store.configuration.targetSegmentDuration)
        guard Double(current.frameCount) / format.sampleRate >= targetSeconds else { return }
        guard pendingFinalizationCount < store.configuration.maximumFinalizingSegmentCountPerSource else {
            if !finalizationIsDelayed {
                finalizationIsDelayed = true
                eventHandler(.finalizationDelayed(source: source))
            }
            return
        }

        let nextOffset = current.record.sessionStartOffsetSeconds
            + Double(current.frameCount) / format.sampleRate
        let next = try await createPhysicalSegment(sessionOffsetSeconds: nextOffset)
        self.current = next
        try await sealAndEnqueueFinalization(current)
    }

    private func createPhysicalSegment(sessionOffsetSeconds: TimeInterval) async throws -> PhysicalSegment {
        let creation = try await store.createSegment(
            meetingId: meetingId,
            sessionId: sessionId,
            source: source,
            segmentIndex: nextSegmentIndex,
            sessionStartOffsetSeconds: sessionOffsetSeconds,
            localeIdentifier: currentLocaleIdentifier,
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount),
            isRequiredSource: requiredSource
        )
        nextSegmentIndex += 1
        do {
            return try PhysicalSegment(creation: creation, format: format)
        } catch {
            try? await store.fail(
                segmentId: creation.record.id,
                stage: "create",
                code: "writerInitializationFailed"
            )
            throw error
        }
    }

    private func sealAndEnqueueFinalization(_ segment: PhysicalSegment) async throws {
        let endOffset = segment.record.sessionStartOffsetSeconds
            + Double(segment.frameCount) / format.sampleRate
        try await store.markFinalizing(
            segmentId: segment.record.id,
            sealedFrameCount: segment.frameCount,
            sessionEndOffsetSeconds: endOffset
        )
        segment.close()
        pendingFinalizationCount += 1
        let estimatedByteCount = segment.frameCount
            * Int64(format.channelCount)
            * Int64(MemoryLayout<Int16>.size)
        pendingFinalizationByteCount += estimatedByteCount
        oldestFinalizationStartedAt = oldestFinalizationStartedAt ?? .now
        let segmentId = segment.record.id
        let previousTask = finalizerTask
        finalizerTask = Task { [weak self, store] in
            await previousTask?.value
            do {
                _ = try await store.finalize(segmentId: segmentId)
                await self?.finalizationCompleted(byteCount: estimatedByteCount)
            } catch {
                await self?.finalizationFailed(error, byteCount: estimatedByteCount)
            }
        }
    }

    private func finalizationCompleted(byteCount: Int64) {
        pendingFinalizationCount = max(0, pendingFinalizationCount - 1)
        pendingFinalizationByteCount = max(0, pendingFinalizationByteCount - byteCount)
        if pendingFinalizationCount == 0 {
            oldestFinalizationStartedAt = nil
        }
        if finalizationIsDelayed,
           pendingFinalizationCount < store.configuration.maximumFinalizingSegmentCountPerSource {
            finalizationIsDelayed = false
            eventHandler(.finalizationRecovered(source: source))
        }
    }

    private func finalizationFailed(_ error: Error, byteCount: Int64) {
        pendingFinalizationCount = max(0, pendingFinalizationCount - 1)
        pendingFinalizationByteCount = max(0, pendingFinalizationByteCount - byteCount)
        if pendingFinalizationCount == 0 {
            oldestFinalizationStartedAt = nil
        }
        recordFailure(error)
    }

    private func enforceActiveSafetyBudget(_ segment: PhysicalSegment) throws {
        let duration = Double(segment.frameCount) / format.sampleRate
        let estimatedBytes = segment.frameCount * Int64(format.channelCount) * Int64(MemoryLayout<Int16>.size)
        guard duration < Self.seconds(store.configuration.maximumActiveSegmentDuration),
              estimatedBytes < store.configuration.maximumActiveSegmentByteCount else {
            throw RecordingAudioStoreError.activeSegmentSafetyLimit
        }
    }

    private func currentBoundary() -> RecordingAudioRangeBoundary? {
        guard let current else { return nil }
        return RecordingAudioRangeBoundary(
            source: source,
            segmentId: current.record.id,
            frame: current.frameCount,
            sessionOffsetSeconds: current.record.sessionStartOffsetSeconds
                + Double(current.frameCount) / format.sampleRate
        )
    }

    private func resumeBoundaryWaitersIfNeeded() -> Bool {
        let ready = boundaryWaiters.filter { totalProcessedFrameCount >= $0.targetFrame }
        boundaryWaiters.removeAll { totalProcessedFrameCount >= $0.targetFrame }
        guard !ready.isEmpty else { return false }
        guard let boundary = currentBoundary() else {
            for waiter in ready {
                waiter.continuation.resume(returning: nil)
            }
            return false
        }
        pendingBoundaryCommitCount += ready.count
        for waiter in ready {
            waiter.continuation.resume(returning: boundary)
        }
        return true
    }

    private func recordFailure(_ error: Error) {
        let storageError = error as? RecordingAudioStoreError ?? .storageUnavailable
        if writeError == nil {
            writeError = storageError
            failCallback(storageError)
            resumeAllBoundaryWaiters(returning: nil)
            cancelAllBoundaryCommits()
            eventHandler(.failed(source: source, error: storageError))
        }
    }

    private func waitForBoundaryCommits() async {
        guard pendingBoundaryCommitCount > 0 else { return }
        await withCheckedContinuation { continuation in
            boundaryCommitWaiter = continuation
        }
    }

    private func completeBoundaryCommit() {
        guard pendingBoundaryCommitCount > 0 else { return }
        pendingBoundaryCommitCount -= 1
        guard pendingBoundaryCommitCount == 0 else { return }
        boundaryCommitWaiter?.resume()
        boundaryCommitWaiter = nil
    }

    private func cancelAllBoundaryCommits() {
        pendingBoundaryCommitCount = 0
        boundaryCommitWaiter?.resume()
        boundaryCommitWaiter = nil
    }

    private func resumeAllBoundaryWaiters(returning boundary: RecordingAudioRangeBoundary?) {
        let waiters = boundaryWaiters
        boundaryWaiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(returning: boundary)
        }
    }

    private nonisolated func failCallback(_ error: RecordingAudioStoreError) {
        callbackState.withLock { state in
            state.error = state.error ?? error
            state.isAcceptingBuffers = false
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
