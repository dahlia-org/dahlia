@preconcurrency import AVFoundation
import Foundation
import GRDB

/// Owns segmented app-managed CAF writers for one batch recording session.
actor BatchAudioRecordingSession {
    static let standardSampleRate = 16000.0

    nonisolated let targetFormat: AVAudioFormat
    nonisolated let events: AsyncStream<BatchRecordingEvent>

    private nonisolated let eventContinuation: AsyncStream<BatchRecordingEvent>.Continuation
    private let store: RecordingAudioStore
    private let meetingId: UUID
    private let recordingSessionId: UUID
    private let recordingStartTime: Date
    private let beforeConsumingChunk: SegmentedAudioSourceWriter.BeforeConsumingChunk?
    private var writers: [RecordingAudioSource: SegmentedAudioSourceWriter] = [:]
    private var requiredSourcesFrozen = false
    private var hasSessionLease = false

    init(
        dbQueue: DatabaseQueue,
        managedRootURL: URL = BatchAudioStorage.managedRootURL,
        meetingId: UUID,
        recordingSessionId: UUID,
        recordingStartTime: Date,
        sampleRate: Double,
        configuration: RecordingAudioStore.Configuration = .production,
        beforeConsumingChunk: SegmentedAudioSourceWriter.BeforeConsumingChunk? = nil
    ) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCaptureError.invalidHardwareFormat
        }
        let eventPair = AsyncStream.makeStream(of: BatchRecordingEvent.self)
        events = eventPair.stream
        eventContinuation = eventPair.continuation
        store = try RecordingAudioStore(
            dbQueue: dbQueue,
            managedRootURL: managedRootURL,
            configuration: configuration
        )
        self.meetingId = meetingId
        self.recordingSessionId = recordingSessionId
        self.recordingStartTime = recordingStartTime
        self.beforeConsumingChunk = beforeConsumingChunk
        targetFormat = format
    }

    func freezeRequiredSources() {
        requiredSourcesFrozen = true
    }

    func beginRange(
        source: RecordingAudioSource,
        locale: Locale,
        at date: Date = .now
    ) async throws -> SegmentedAudioSourceWriter {
        try await beginRangeWithOrigin(
            source: source,
            locale: locale,
            at: date,
            continuingFromActiveRange: false
        ).writer
    }

    func beginRangeWithOrigin(
        source: RecordingAudioSource,
        locale: Locale,
        at date: Date,
        continuingFromActiveRange: Bool
    ) async throws -> (writer: SegmentedAudioSourceWriter, origin: BatchRecordingRangeOrigin) {
        if let existing = writers[source] {
            guard let boundary = await existing.captureLocaleBoundary() else {
                throw RecordingAudioStoreError.invalidState
            }
            do {
                try await store.rotateLocaleRanges(
                    boundaries: [boundary],
                    localeIdentifier: locale.identifier
                )
            } catch {
                await existing.cancelLocaleBoundary()
                throw error
            }
            await existing.commitLocale(locale)
            return (
                existing,
                BatchRecordingRangeOrigin(
                    source: source,
                    startFrame: existing.acceptedFrameCount,
                    sessionRelativeOriginSeconds: boundary.sessionOffsetSeconds
                )
            )
        }

        let writer = try await writer(
            for: source,
            locale: locale,
            at: date,
            continuingFromActiveRange: continuingFromActiveRange
        )
        let offset = max(0, date.timeIntervalSince(recordingStartTime))
        return (
            writer,
            BatchRecordingRangeOrigin(
                source: source,
                startFrame: 0,
                sessionRelativeOriginSeconds: offset
            )
        )
    }

    @discardableResult
    func rotateRange(
        source: RecordingAudioSource,
        locale: Locale,
        at _: Date = .now
    ) async throws -> SegmentedAudioSourceWriter {
        guard let writer = writers[source], let boundary = await writer.captureLocaleBoundary() else {
            throw RecordingAudioStoreError.invalidState
        }
        do {
            try await store.rotateLocaleRanges(
                boundaries: [boundary],
                localeIdentifier: locale.identifier
            )
        } catch {
            await writer.cancelLocaleBoundary()
            throw error
        }
        await writer.commitLocale(locale)
        return writer
    }

    @discardableResult
    func rotateRanges(
        _ sourceOrigins: [BatchRecordingRangeOrigin],
        locale: Locale
    ) async throws -> [RecordingAudioSource: BatchRecordingRangeOrigin] {
        var boundaries: [RecordingAudioRangeBoundary] = []
        for source in sourceOrigins.map(\.source) {
            guard let writer = writers[source] else { continue }
            guard let boundary = await writer.captureLocaleBoundary() else {
                for capturedBoundary in boundaries {
                    await writers[capturedBoundary.source]?.cancelLocaleBoundary()
                }
                throw RecordingAudioStoreError.invalidState
            }
            boundaries.append(boundary)
        }
        do {
            try await store.rotateLocaleRanges(
                boundaries: boundaries,
                localeIdentifier: locale.identifier
            )
        } catch {
            for boundary in boundaries {
                await writers[boundary.source]?.cancelLocaleBoundary()
            }
            throw error
        }
        var result: [RecordingAudioSource: BatchRecordingRangeOrigin] = [:]
        for boundary in boundaries {
            guard let writer = writers[boundary.source] else { continue }
            await writer.commitLocale(locale)
            result[boundary.source] = BatchRecordingRangeOrigin(
                source: boundary.source,
                startFrame: writer.acceptedFrameCount,
                sessionRelativeOriginSeconds: boundary.sessionOffsetSeconds
            )
        }
        return result
    }

    func endActiveRanges() async throws {
        // Open ranges are sealed atomically with their physical segment during finish.
    }

    func endRangeForReconfiguration(source: RecordingAudioSource) async throws {
        guard let writer = writers.removeValue(forKey: source) else { return }
        try await writer.finish()
    }

    func finish() async throws {
        writers.values.forEach { $0.seal() }
        var firstError: Error?
        for source in writers.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            do {
                try await writers[source]?.finish()
            } catch {
                firstError = firstError ?? error
            }
        }
        writers.removeAll()
        if hasSessionLease {
            await store.releaseSessionLease(sessionId: recordingSessionId)
            hasSessionLease = false
        }
        eventContinuation.finish()
        if let firstError {
            throw firstError
        }
    }

    /// Abort preserves any accepted audio by running the same durable finalization path.
    func cancelPreservingAudio() async {
        try? await finish()
    }

    func fullyDurableThroughOffsetSeconds() async -> TimeInterval {
        await (try? store.fullyDurableThroughOffsetSeconds(sessionId: recordingSessionId)) ?? 0
    }

    private func writer(
        for source: RecordingAudioSource,
        locale: Locale,
        at date: Date,
        continuingFromActiveRange _: Bool
    ) async throws -> SegmentedAudioSourceWriter {
        if let writer = writers[source] {
            return writer
        }
        if !hasSessionLease {
            try await store.acquireSessionLease(meetingId: meetingId, sessionId: recordingSessionId)
            hasSessionLease = true
        }
        let firstSegmentIndex = try await store.nextSegmentIndex(
            sessionId: recordingSessionId,
            source: source
        )
        let writer = SegmentedAudioSourceWriter(
            source: source,
            format: targetFormat,
            store: store,
            meetingId: meetingId,
            sessionId: recordingSessionId,
            locale: locale,
            firstSegmentIndex: firstSegmentIndex,
            requiredSource: !requiredSourcesFrozen,
            beforeConsumingChunk: beforeConsumingChunk,
            eventHandler: { [eventContinuation] event in
                switch event {
                case let .finalizationDelayed(source):
                    eventContinuation.yield(.finalizationDelayed(source: source))
                case let .finalizationRecovered(source):
                    eventContinuation.yield(.finalizationRecovered(source: source))
                case let .failed(source, error):
                    eventContinuation.yield(.failed(source: source, error: error))
                }
            }
        )
        let offset = max(0, date.timeIntervalSince(recordingStartTime))
        try await writer.start(sessionOffsetSeconds: offset)
        writers[source] = writer
        return writer
    }
}
