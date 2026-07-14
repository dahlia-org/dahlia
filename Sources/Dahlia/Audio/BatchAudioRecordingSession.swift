@preconcurrency import AVFoundation
import Foundation
import GRDB

private struct RangeRotation {
    let source: RecordingAudioSource
    let previousRange: RecordingAudioRangeRecord?
    let newRange: RecordingAudioRangeRecord
}

private struct RangeRotationRequest {
    let source: RecordingAudioSource
    let offsetBasis: RangeOffsetBasis
}

private enum RangeOffsetBasis {
    case fixed(TimeInterval)
    case sourceOrigin(BatchRecordingRangeOrigin)

    func sessionOffsetSeconds(boundaryFrame: Int64, sampleRate: Double) -> TimeInterval {
        switch self {
        case let .fixed(offset):
            offset
        case let .sourceOrigin(origin):
            origin.sessionRelativeOriginSeconds
                + Double(max(0, boundaryFrame - origin.startFrame)) / sampleRate
        }
    }
}

private struct RangePersistence {
    let previousRange: RecordingAudioRangeRecord?
    let newRange: RecordingAudioRangeRecord
}

/// ひとつのバッチ録音セッションで、音源ごとの単一CAFとrangeを管理する。
actor BatchAudioRecordingSession {
    static let standardSampleRate = 16000.0

    nonisolated let targetFormat: AVAudioFormat

    private let dbQueue: DatabaseQueue
    private let managedRootURL: URL
    private let meetingId: UUID
    private let recordingSessionId: UUID
    private let recordingStartTime: Date
    private var writers: [RecordingAudioSource: BatchAudioFileWriter] = [:]
    private var fileRecords: [RecordingAudioSource: RecordingAudioFileRecord] = [:]
    private var activeRanges: [RecordingAudioSource: RecordingAudioRangeRecord] = [:]

    init(
        dbQueue: DatabaseQueue,
        managedRootURL: URL = BatchAudioStorage.managedRootURL,
        meetingId: UUID,
        recordingSessionId: UUID,
        recordingStartTime: Date,
        sampleRate: Double
    ) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCaptureError.invalidHardwareFormat
        }
        self.dbQueue = dbQueue
        self.managedRootURL = managedRootURL
        self.meetingId = meetingId
        self.recordingSessionId = recordingSessionId
        self.recordingStartTime = recordingStartTime
        self.targetFormat = format
    }

    /// capture の開始時刻を確定する前に、対象音源のCAF writerを準備する。
    func prepareWriter(for source: RecordingAudioSource) async throws -> BatchAudioFileWriter {
        try await writer(for: source)
    }

    func beginRange(
        source: RecordingAudioSource,
        locale: Locale,
        at date: Date = .now
    ) async throws -> BatchAudioFileWriter {
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
    ) async throws -> (writer: BatchAudioFileWriter, origin: BatchRecordingRangeOrigin) {
        let previousRange = activeRanges[source]
        try await endRange(source: source)
        let writer = try await writer(for: source)
        let audioFile = try fileRecord(for: source)
        let startFrame = writer.appendedFrameCount
        let sessionOffsetSeconds: TimeInterval = if continuingFromActiveRange, let previousRange {
            previousRange.sessionOffsetSeconds
                + Double(max(0, startFrame - previousRange.startFrame)) / targetFormat.sampleRate
        } else {
            max(0, date.timeIntervalSince(recordingStartTime))
        }
        let now = Date.now
        let range = RecordingAudioRangeRecord(
            id: .v7(),
            audioFileId: audioFile.id,
            startFrame: startFrame,
            frameCount: nil,
            sessionOffsetSeconds: sessionOffsetSeconds,
            localeIdentifier: locale.identifier,
            createdAt: now,
            updatedAt: now
        )
        try await dbQueue.write { db in
            try range.insert(db)
        }
        activeRanges[source] = range
        return (
            writer,
            BatchRecordingRangeOrigin(
                source: source,
                startFrame: startFrame,
                sessionRelativeOriginSeconds: sessionOffsetSeconds
            )
        )
    }

    /// capture を止めず、同一フレーム境界で locale range を切り替える。
    func rotateRange(source: RecordingAudioSource, locale: Locale, at date: Date = .now) async throws -> BatchAudioFileWriter {
        let writer = try await writer(for: source)
        _ = try await performRangeRotation(
            [
                RangeRotationRequest(
                    source: source,
                    offsetBasis: .fixed(date.timeIntervalSince(recordingStartTime))
                ),
            ],
            locale: locale
        )
        return writer
    }

    /// 複数音源の locale range を、各CAFの同一フレーム境界で原子的に切り替える。
    /// originは各range先頭フレームと、そのフレームのセッション相対時刻を対で保持する。
    @discardableResult
    func rotateRanges(
        _ sourceOrigins: [BatchRecordingRangeOrigin],
        locale: Locale
    ) async throws -> [RecordingAudioSource: BatchRecordingRangeOrigin] {
        try await performRangeRotation(
            sourceOrigins.map {
                RangeRotationRequest(
                    source: $0.source,
                    offsetBasis: .sourceOrigin($0)
                )
            },
            locale: locale
        )
    }

    private func performRangeRotation(
        _ requests: [RangeRotationRequest],
        locale: Locale
    ) async throws -> [RecordingAudioSource: BatchRecordingRangeOrigin] {
        var seenSources: Set<RecordingAudioSource> = []
        let uniqueRequests = requests.filter { seenSources.insert($0.source).inserted }
        var rotations: [RangeRotation] = []

        for request in uniqueRequests {
            try await rotations.append(makeRotation(request, locale: locale))
        }

        let persistedRotations = rotations.map {
            RangePersistence(previousRange: $0.previousRange, newRange: $0.newRange)
        }
        try await dbQueue.write { db in
            for rotation in persistedRotations {
                if let previousRange = rotation.previousRange {
                    try previousRange.update(db)
                }
                try rotation.newRange.insert(db)
            }
        }
        for rotation in rotations {
            activeRanges[rotation.source] = rotation.newRange
        }
        return Dictionary(uniqueKeysWithValues: rotations.map { rotation in
            (
                rotation.source,
                BatchRecordingRangeOrigin(
                    source: rotation.source,
                    startFrame: rotation.newRange.startFrame,
                    sessionRelativeOriginSeconds: rotation.newRange.sessionOffsetSeconds
                )
            )
        })
    }

    private func makeRotation(
        _ request: RangeRotationRequest,
        locale: Locale
    ) async throws -> RangeRotation {
        let source = request.source
        let writer = try await writer(for: source)
        let audioFile = try fileRecord(for: source)
        let boundaryFrame = writer.appendedFrameCount
        let now = Date.now
        var previousRange = activeRanges[source]
        if var updatedRange = previousRange {
            updatedRange.frameCount = max(0, boundaryFrame - updatedRange.startFrame)
            updatedRange.updatedAt = now
            previousRange = updatedRange
        }
        let sessionOffsetSeconds = request.offsetBasis.sessionOffsetSeconds(
            boundaryFrame: boundaryFrame,
            sampleRate: targetFormat.sampleRate
        )
        let newRange = RecordingAudioRangeRecord(
            id: .v7(),
            audioFileId: audioFile.id,
            startFrame: boundaryFrame,
            frameCount: nil,
            sessionOffsetSeconds: max(0, sessionOffsetSeconds),
            localeIdentifier: locale.identifier,
            createdAt: now,
            updatedAt: now
        )
        return RangeRotation(source: source, previousRange: previousRange, newRange: newRange)
    }

    func endActiveRanges() async throws {
        var firstError: Error?
        for source in Array(activeRanges.keys) {
            do {
                try await endRange(source: source)
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }
        if let firstError {
            throw firstError
        }
    }

    func endRangeForReconfiguration(source: RecordingAudioSource) async throws {
        try await endRange(source: source)
    }

    func finish() async throws {
        writers.values.forEach { $0.seal() }
        var firstError: Error?
        do {
            try await endActiveRanges()
        } catch {
            if firstError == nil {
                firstError = error
            }
        }

        for (source, writer) in writers {
            do {
                let totalFrames = try await writer.finish()
                guard var fileRecord = fileRecords[source] else { continue }
                let now = Date.now
                fileRecord.finalizedAt = now
                fileRecord.totalFrameCount = totalFrames
                fileRecord.updatedAt = now
                let updatedRecord = fileRecord
                try await dbQueue.write { db in
                    try updatedRecord.update(db)
                }
                fileRecords[source] = fileRecord
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        if let firstError {
            throw firstError
        }
    }

    func cancelAndDelete() async {
        for writer in writers.values {
            await writer.cancelAndDelete()
        }
        try? await dbQueue.write { db in
            _ = try RecordingAudioFileRecord
                .filter(Column("recordingSessionId") == recordingSessionId)
                .deleteAll(db)
        }
    }

    private func writer(for source: RecordingAudioSource) async throws -> BatchAudioFileWriter {
        if let writer = writers[source] {
            return writer
        }

        let relativePath = BatchAudioStorage.managedRelativePath(
            meetingId: meetingId,
            sessionId: recordingSessionId,
            source: source
        )
        let now = Date.now
        let record = RecordingAudioFileRecord(
            id: .v7(),
            recordingSessionId: recordingSessionId,
            source: source,
            storageLocation: .managed,
            relativePath: relativePath,
            sampleRate: targetFormat.sampleRate,
            channelCount: Int(targetFormat.channelCount),
            finalizedAt: nil,
            totalFrameCount: nil,
            createdAt: now,
            updatedAt: now
        )
        try await dbQueue.write { db in
            try record.insert(db)
        }

        let writer = BatchAudioFileWriter(
            partialURL: BatchAudioStorage.partialURL(baseURL: managedRootURL, relativePath: relativePath),
            finalURL: BatchAudioStorage.finalURL(baseURL: managedRootURL, relativePath: relativePath),
            format: targetFormat
        )
        do {
            try await writer.start()
        } catch {
            try? await dbQueue.write { db in
                _ = try RecordingAudioFileRecord.deleteOne(db, key: record.id)
            }
            throw error
        }
        writers[source] = writer
        fileRecords[source] = record
        return writer
    }

    private func fileRecord(for source: RecordingAudioSource) throws -> RecordingAudioFileRecord {
        guard let record = fileRecords[source] else {
            throw BatchAudioFileWriterError.incompatibleBuffer
        }
        return record
    }

    private func endRange(source: RecordingAudioSource) async throws {
        guard var range = activeRanges[source],
              let writer = writers[source] else { return }
        range.frameCount = max(0, writer.appendedFrameCount - range.startFrame)
        range.updatedAt = .now
        let updatedRange = range
        try await dbQueue.write { db in
            try updatedRange.update(db)
        }
        if activeRanges[source]?.id == updatedRange.id {
            activeRanges.removeValue(forKey: source)
        }
    }

}
