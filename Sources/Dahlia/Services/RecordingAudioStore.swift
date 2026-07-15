@preconcurrency import AVFoundation
import CryptoKit
import Darwin
import Foundation
import GRDB

/// The sole mutation boundary for app-managed recording audio.
actor RecordingAudioStore {
    private enum FilePresence: Equatable {
        case missing
        case regular
        case symbolicLink
        case inaccessible
    }

    struct ReconciliationResult: Equatable {
        var recoveredSegmentCount = 0
        var failedSegmentCount = 0
        var purgedSegmentCount = 0
        var skippedActiveSessionCount = 0
        var orphanCount = 0
    }

    struct Configuration: Equatable {
        let targetSegmentDuration: Duration
        let maximumFinalizingSegmentCountPerSource: Int
        let maximumActiveSegmentDuration: Duration
        let maximumActiveSegmentByteCount: Int64
        let minimumAvailableCapacity: Int64
        let capacityCheckInterval: Duration
        let simulatedFinalizationDelay: Duration

        init(
            targetSegmentDuration: Duration,
            maximumFinalizingSegmentCountPerSource: Int,
            maximumActiveSegmentDuration: Duration,
            maximumActiveSegmentByteCount: Int64,
            minimumAvailableCapacity: Int64,
            capacityCheckInterval: Duration,
            simulatedFinalizationDelay: Duration = .zero
        ) {
            self.targetSegmentDuration = targetSegmentDuration
            self.maximumFinalizingSegmentCountPerSource = maximumFinalizingSegmentCountPerSource
            self.maximumActiveSegmentDuration = maximumActiveSegmentDuration
            self.maximumActiveSegmentByteCount = maximumActiveSegmentByteCount
            self.minimumAvailableCapacity = minimumAvailableCapacity
            self.capacityCheckInterval = capacityCheckInterval
            self.simulatedFinalizationDelay = simulatedFinalizationDelay
        }

        static let production = Configuration(
            targetSegmentDuration: .seconds(60),
            maximumFinalizingSegmentCountPerSource: 2,
            maximumActiveSegmentDuration: .seconds(600),
            maximumActiveSegmentByteCount: 64 * 1024 * 1024,
            minimumAvailableCapacity: 1024 * 1024 * 1024,
            capacityCheckInterval: .seconds(5)
        )
    }

    struct SegmentCreation {
        let record: RecordingAudioSegmentRecord
        let partialURL: URL
    }

    struct VerifiedSegment {
        let segment: RecordingAudioSegmentRecord
        let url: URL
        let ranges: [RecordingAudioSegmentRangeRecord]
    }

    let configuration: Configuration

    private let dbQueue: DatabaseQueue
    private let managedRootURL: URL
    private var sessionLeases: [UUID: AdvisoryFileLock] = [:]
    private var readLeaseCounts: [UUID: Int] = [:]
    private var lastCapacityChecks: [String: ContinuousClock.Instant] = [:]

    init(
        dbQueue: DatabaseQueue,
        managedRootURL: URL = BatchAudioStorage.managedRootURL,
        configuration: Configuration = .production
    ) throws {
        self.dbQueue = dbQueue
        self.managedRootURL = managedRootURL.standardizedFileURL
        self.configuration = configuration
        try Self.ensureDirectory(at: self.managedRootURL)
        try Self.repairManagedPermissions(rootURL: self.managedRootURL)
    }

    func acquireSessionLease(meetingId: UUID, sessionId: UUID) throws {
        guard sessionLeases[sessionId] == nil else { return }
        let directoryURL = sessionDirectoryURL(meetingId: meetingId, sessionId: sessionId)
        guard try !Self.parentPathContainsSymbolicLink(directoryURL, stoppingAt: managedRootURL) else {
            throw RecordingAudioStoreError.invalidPath
        }
        try Self.ensureDirectory(at: directoryURL)
        let lease = try AdvisoryFileLock.acquire(at: directoryURL.appending(path: ".lease"))
        sessionLeases[sessionId] = lease
    }

    func releaseSessionLease(sessionId: UUID) {
        sessionLeases[sessionId] = nil
    }

    func createSegment(
        meetingId: UUID,
        sessionId: UUID,
        source: RecordingAudioSource,
        segmentIndex: Int,
        sessionStartOffsetSeconds: TimeInterval,
        localeIdentifier: String,
        sampleRate: Double,
        channelCount: Int,
        isRequiredSource: Bool,
        at now: Date = .now
    ) async throws -> SegmentCreation {
        guard sessionLeases[sessionId] != nil else {
            throw RecordingAudioStoreError.missingSessionLease
        }
        try ensureAvailableCapacity()

        let generationId = UUID.v7()
        let formattedIndex = segmentIndex.formatted(
            .number
                .grouping(.never)
                .precision(.integerLength(6))
        )
        let baseName = "\(source.rawValue)-\(formattedIndex)-\(generationId.uuidString.lowercased())"
        let directoryPath = "\(meetingId.uuidString)/\(sessionId.uuidString)"
        let partialRelativePath = "\(directoryPath)/\(baseName).partial.caf"
        let finalRelativePath = "\(directoryPath)/\(baseName).caf"
        let record = RecordingAudioSegmentRecord(
            id: .v7(),
            recordingSessionId: sessionId,
            source: source,
            segmentIndex: segmentIndex,
            generationId: generationId,
            state: .recording,
            partialRelativePath: partialRelativePath,
            finalRelativePath: finalRelativePath,
            sampleRate: sampleRate,
            channelCount: channelCount,
            sealedFrameCount: nil,
            sessionStartOffsetSeconds: max(0, sessionStartOffsetSeconds),
            sessionEndOffsetSeconds: nil,
            byteCount: nil,
            sha256: nil,
            finalizationStartedAt: nil,
            integrityVerifiedAt: nil,
            finalizedAt: nil,
            purgeRequestedAt: nil,
            purgedAt: nil,
            failureStage: nil,
            failureCode: nil,
            createdAt: now,
            updatedAt: now
        )
        let range = RecordingAudioSegmentRangeRecord(
            id: .v7(),
            audioSegmentId: record.id,
            startFrame: 0,
            frameCount: nil,
            sessionOffsetSeconds: record.sessionStartOffsetSeconds,
            localeIdentifier: localeIdentifier,
            createdAt: now,
            updatedAt: now
        )
        let progress = RecordingAudioSourceProgressRecord(
            recordingSessionId: sessionId,
            source: source,
            isRequired: isRequiredSource,
            captureState: .active,
            durableThroughOffsetSeconds: 0,
            lastContiguousReadySegmentIndex: nil,
            failureCode: nil,
            createdAt: now,
            updatedAt: now
        )
        try await dbQueue.write { db in
            try record.insert(db)
            try range.insert(db)
            if var existing = try RecordingAudioSourceProgressRecord.fetchOne(
                db,
                key: ["recordingSessionId": sessionId, "source": source]
            ) {
                // Once a source participates in the required set, reconfiguration and
                // later segments must never remove it or reset its durability cursor.
                existing.isRequired = existing.isRequired || isRequiredSource
                existing.captureState = .active
                existing.failureCode = nil
                existing.updatedAt = now
                try existing.update(db)
            } else {
                try progress.insert(db)
            }
        }
        return try SegmentCreation(record: record, partialURL: safeURL(relativePath: partialRelativePath))
    }

    func nextSegmentIndex(sessionId: UUID, source: RecordingAudioSource) async throws -> Int {
        try await dbQueue.read { db in
            let maximum = try Int.fetchOne(
                db,
                sql: """
                SELECT MAX(segmentIndex)
                FROM recording_audio_segments
                WHERE recordingSessionId = ? AND source = ?
                """,
                arguments: [sessionId, source.rawValue]
            )
            return maximum.map { $0 + 1 } ?? 0
        }
    }

    func ensureAvailableCapacityIfNeeded(sessionId: UUID, source: RecordingAudioSource) throws {
        let key = "\(sessionId.uuidString):\(source.rawValue)"
        let now = ContinuousClock.now
        if let lastCheck = lastCapacityChecks[key],
           lastCheck.duration(to: now) < configuration.capacityCheckInterval {
            return
        }
        try ensureAvailableCapacity()
        lastCapacityChecks[key] = now
    }

    func markFinalizing(
        segmentId: UUID,
        sealedFrameCount: Int64,
        sessionEndOffsetSeconds: TimeInterval,
        at now: Date = .now
    ) async throws {
        try await dbQueue.write { db in
            guard var record = try RecordingAudioSegmentRecord.fetchOne(db, key: segmentId),
                  record.state == .recording else {
                throw RecordingAudioStoreError.invalidState
            }
            record.state = .finalizing
            record.sealedFrameCount = sealedFrameCount
            record.sessionEndOffsetSeconds = max(record.sessionStartOffsetSeconds, sessionEndOffsetSeconds)
            record.finalizationStartedAt = now
            record.updatedAt = now
            try record.update(db)

            let ranges = try RecordingAudioSegmentRangeRecord
                .filter(Column("audioSegmentId") == segmentId)
                .filter(Column("frameCount") == nil)
                .fetchAll(db)
            for var range in ranges {
                range.frameCount = max(0, sealedFrameCount - range.startFrame)
                range.updatedAt = now
                try range.update(db)
            }
        }
    }

    func rotateLocaleRanges(
        boundaries: [RecordingAudioRangeBoundary],
        localeIdentifier: String,
        at now: Date = .now
    ) async throws {
        try await dbQueue.write { db in
            for boundary in boundaries {
                guard let segment = try RecordingAudioSegmentRecord.fetchOne(db, key: boundary.segmentId),
                      segment.source == boundary.source,
                      segment.state == .recording else {
                    throw RecordingAudioStoreError.invalidState
                }
                let openRanges = try RecordingAudioSegmentRangeRecord
                    .filter(Column("audioSegmentId") == boundary.segmentId)
                    .filter(Column("frameCount") == nil)
                    .fetchAll(db)
                var reusedOpenRange = false
                for var range in openRanges {
                    if range.startFrame == boundary.frame {
                        range.localeIdentifier = localeIdentifier
                        reusedOpenRange = true
                    } else {
                        range.frameCount = max(0, boundary.frame - range.startFrame)
                    }
                    range.updatedAt = now
                    try range.update(db)
                }
                guard !reusedOpenRange else { continue }
                let range = RecordingAudioSegmentRangeRecord(
                    id: .v7(),
                    audioSegmentId: boundary.segmentId,
                    startFrame: boundary.frame,
                    frameCount: nil,
                    sessionOffsetSeconds: boundary.sessionOffsetSeconds,
                    localeIdentifier: localeIdentifier,
                    createdAt: now,
                    updatedAt: now
                )
                try range.insert(db)
            }
        }
    }

    func finalize(segmentId: UUID) async throws -> RecordingAudioSegmentRecord {
        let record = try await fetchSegment(id: segmentId)
        guard record.state == .finalizing, let expectedFrameCount = record.sealedFrameCount else {
            throw RecordingAudioStoreError.invalidState
        }
        let partialURL = try safeURL(relativePath: record.partialRelativePath)
        let finalURL = try safeURL(relativePath: record.finalRelativePath)
        if configuration.simulatedFinalizationDelay > .zero {
            try await Task.sleep(for: configuration.simulatedFinalizationDelay)
        }
        let metadata: RecordingAudioIntegrityMetadata
        do {
            metadata = try await Task.detached(priority: .utility) {
                try Self.durablyVerify(
                    url: partialURL,
                    expectedFrameCount: expectedFrameCount,
                    expectedSampleRate: record.sampleRate,
                    expectedChannelCount: record.channelCount
                )
            }.value
        } catch RecordingAudioStoreError.integrityMismatch {
            try await fail(segmentId: segmentId, stage: "finalize", code: "integrityMismatch")
            throw RecordingAudioStoreError.integrityMismatch
        } catch RecordingAudioStoreError.missingFile {
            try await fail(segmentId: segmentId, stage: "finalize", code: "missingPartial")
            throw RecordingAudioStoreError.missingFile
        } catch {
            throw error
        }
        if let expectedMetadata = Self.expectedIntegrityMetadata(for: record) {
            guard metadata == expectedMetadata else {
                try await fail(segmentId: segmentId, stage: "finalize", code: "integrityMismatch")
                throw RecordingAudioStoreError.integrityMismatch
            }
        } else {
            guard record.byteCount == nil, record.sha256 == nil, record.integrityVerifiedAt == nil else {
                try await fail(segmentId: segmentId, stage: "finalize", code: "partialIntegrityMetadata")
                throw RecordingAudioStoreError.integrityMismatch
            }
            let verifiedAt = Date.now
            try await dbQueue.write { db in
                guard var current = try RecordingAudioSegmentRecord.fetchOne(db, key: segmentId),
                      current.state == .finalizing else {
                    throw RecordingAudioStoreError.invalidState
                }
                current.byteCount = metadata.byteCount
                current.sha256 = metadata.sha256
                current.integrityVerifiedAt = verifiedAt
                current.updatedAt = verifiedAt
                try current.update(db)
            }
        }

        guard Self.filePresence(at: finalURL) == .missing else {
            try await fail(segmentId: segmentId, stage: "publish", code: "destinationExists")
            throw RecordingAudioStoreError.ambiguousFiles
        }
        do {
            try Self.publishExclusive(from: partialURL, to: finalURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: finalURL.path)
        } catch {
            throw RecordingAudioStoreError.storageUnavailable
        }
        return try await markReady(segmentId: segmentId)
    }

    func fail(segmentId: UUID, stage: String, code: String, at now: Date = .now) async throws {
        try await dbQueue.write { db in
            guard var record = try RecordingAudioSegmentRecord.fetchOne(db, key: segmentId),
                  record.state != .purged else { return }
            record.state = .failed
            record.failureStage = stage
            record.failureCode = code
            record.updatedAt = now
            try record.update(db)
            try Self.advanceDurabilityCursor(
                sessionId: record.recordingSessionId,
                source: record.source,
                at: now,
                in: db
            )
            if var progress = try RecordingAudioSourceProgressRecord.fetchOne(
                db,
                key: ["recordingSessionId": record.recordingSessionId, "source": record.source]
            ) {
                progress.captureState = .failed
                progress.failureCode = code
                progress.updatedAt = now
                try progress.update(db)
            }
        }
    }

    func markSourceEnded(sessionId: UUID, source: RecordingAudioSource, at now: Date = .now) async throws {
        try await dbQueue.write { db in
            guard var progress = try RecordingAudioSourceProgressRecord.fetchOne(
                db,
                key: ["recordingSessionId": sessionId, "source": source]
            ), progress.captureState != .failed else { return }
            progress.captureState = .ended
            progress.updatedAt = now
            try progress.update(db)
        }
    }

    func fullyDurableThroughOffsetSeconds(sessionId: UUID) async throws -> TimeInterval {
        try await dbQueue.read { db in
            try Double.fetchOne(
                db,
                sql: """
                SELECT MIN(durableThroughOffsetSeconds)
                FROM recording_audio_source_progress
                WHERE recordingSessionId = ? AND isRequired = 1
                """,
                arguments: [sessionId]
            ) ?? 0
        }
    }

    func withVerifiedReadySegments<T: Sendable>(
        sessionId: UUID,
        operation: @Sendable ([VerifiedSegment]) async throws -> T
    ) async throws -> T {
        let temporaryLease = try await acquireTemporarySessionLease(sessionId: sessionId)
        defer { withExtendedLifetime(temporaryLease) {} }
        readLeaseCounts[sessionId, default: 0] += 1
        defer {
            let remaining = max(0, readLeaseCounts[sessionId, default: 1] - 1)
            readLeaseCounts[sessionId] = remaining == 0 ? nil : remaining
        }
        let records = try await dbQueue.read { db in
            try RecordingAudioSegmentRecord
                .filter(Column("recordingSessionId") == sessionId)
                .order(Column("source").asc, Column("segmentIndex").asc)
                .fetchAll(db)
        }
        guard !records.isEmpty else { throw RecordingAudioStoreError.missingFile }
        guard records.allSatisfy({ $0.state == .ready }), Self.hasContiguousSegmentIndices(records) else {
            throw RecordingAudioStoreError.invalidState
        }
        var verified: [VerifiedSegment] = []
        for record in records {
            guard let expectedFrames = record.sealedFrameCount,
                  let expectedBytes = record.byteCount,
                  let expectedDigest = record.sha256 else {
                try await fail(segmentId: record.id, stage: "read", code: "missingIntegrityMetadata")
                throw RecordingAudioStoreError.integrityMismatch
            }
            let url = try safeURL(relativePath: record.finalRelativePath)
            do {
                let metadata = try await Task.detached(priority: .utility) {
                    try Self.verify(
                        url: url,
                        expectedFrameCount: expectedFrames,
                        expectedSampleRate: record.sampleRate,
                        expectedChannelCount: record.channelCount
                    )
                }.value
                guard metadata.byteCount == expectedBytes, metadata.sha256 == expectedDigest else {
                    throw RecordingAudioStoreError.integrityMismatch
                }
                let ranges = try await dbQueue.read { db in
                    try RecordingAudioSegmentRangeRecord
                        .filter(Column("audioSegmentId") == record.id)
                        .order(Column("startFrame").asc)
                        .fetchAll(db)
                }
                verified.append(VerifiedSegment(segment: record, url: url, ranges: ranges))
            } catch RecordingAudioStoreError.integrityMismatch {
                try await fail(segmentId: record.id, stage: "read", code: "integrityMismatch")
                throw RecordingAudioStoreError.integrityMismatch
            } catch RecordingAudioStoreError.missingFile {
                try await fail(segmentId: record.id, stage: "read", code: "missingFinal")
                throw RecordingAudioStoreError.missingFile
            }
        }
        return try await operation(verified)
    }

    func requestPurge(sessionId: UUID, includeFailed: Bool = false, at now: Date = .now) async throws {
        guard sessionLeases[sessionId] == nil, readLeaseCounts[sessionId] == nil else {
            throw RecordingAudioStoreError.activeSession
        }
        let temporaryLease = try await acquireTemporarySessionLease(sessionId: sessionId)
        defer { withExtendedLifetime(temporaryLease) {} }
        try await dbQueue.write { db in
            let records = try RecordingAudioSegmentRecord
                .filter(Column("recordingSessionId") == sessionId)
                .fetchAll(db)
            for var record in records {
                switch record.state {
                case .ready:
                    break
                case .purgePending, .purged:
                    continue
                case .failed where includeFailed:
                    break
                case .recording, .finalizing, .failed:
                    throw RecordingAudioStoreError.invalidState
                }
                record.state = .purgePending
                record.purgeRequestedAt = now
                record.updatedAt = now
                try record.update(db)
            }
        }
        try await purgePendingLocked(sessionId: sessionId, includeAmbiguousFailedFiles: includeFailed)
    }

    /// Moves every deletable segment to its terminal tombstone before a parent DB row
    /// is allowed to cascade away the only metadata reference.
    func prepareForParentDeletion(sessionIds: [UUID]) async throws {
        for sessionId in sessionIds {
            let count = try await dbQueue.read { db in
                try RecordingAudioSegmentRecord
                    .filter(Column("recordingSessionId") == sessionId)
                    .fetchCount(db)
            }
            guard count > 0 else { continue }
            try await requestPurge(sessionId: sessionId, includeFailed: true)
            let hasLiveReference = try await dbQueue.read { db in
                try RecordingAudioSegmentRecord
                    .filter(Column("recordingSessionId") == sessionId)
                    .filter(Column("state") != RecordingAudioSegmentState.purged.rawValue)
                    .fetchCount(db) > 0
            }
            guard !hasLiveReference else { throw RecordingAudioStoreError.invalidState }
        }
    }

    func purgePending(sessionId: UUID, includeAmbiguousFailedFiles: Bool = false) async throws {
        guard sessionLeases[sessionId] == nil, readLeaseCounts[sessionId] == nil else {
            throw RecordingAudioStoreError.activeSession
        }
        let temporaryLease = try await acquireTemporarySessionLease(sessionId: sessionId)
        defer { withExtendedLifetime(temporaryLease) {} }
        try await purgePendingLocked(
            sessionId: sessionId,
            includeAmbiguousFailedFiles: includeAmbiguousFailedFiles
        )
    }

    /// Reconciles persisted segment state only when this process can prove exclusive
    /// ownership of the corresponding recording session.
    func reconcileStartup() async -> ReconciliationResult {
        var result = ReconciliationResult()
        let sessionIds = await (try? dbQueue.read { db in
            try UUID.fetchAll(
                db,
                sql: "SELECT DISTINCT recordingSessionId FROM recording_audio_segments"
            )
        }) ?? []

        for sessionId in sessionIds {
            let lease: AdvisoryFileLock
            do {
                lease = try await acquireTemporarySessionLease(sessionId: sessionId)
            } catch RecordingAudioStoreError.activeSession {
                result.skippedActiveSessionCount += 1
                continue
            } catch {
                continue
            }

            let segmentIds = await (try? dbQueue.read { db in
                try UUID.fetchAll(
                    db,
                    sql: """
                    SELECT id FROM recording_audio_segments
                    WHERE recordingSessionId = ?
                    ORDER BY source, segmentIndex
                    """,
                    arguments: [sessionId]
                )
            }) ?? []
            for segmentId in segmentIds {
                do {
                    let changedState = try await reconcile(segmentId: segmentId)
                    switch changedState {
                    case .ready:
                        result.recoveredSegmentCount += 1
                    case .failed:
                        result.failedSegmentCount += 1
                    case .purged:
                        result.purgedSegmentCount += 1
                    default:
                        break
                    }
                } catch {
                    // Access denial and unavailable storage are retryable. Preserve the
                    // persisted state and payload instead of collapsing them to missing.
                }
            }
            try? await reconcileSessionState(sessionId: sessionId)
            withExtendedLifetime(lease) {}
        }
        result.orphanCount = await (try? recordOrphans()) ?? 0
        return result
    }

    private func reconcileSessionState(sessionId: UUID) async throws {
        try await dbQueue.write { db in
            guard var session = try RecordingSessionRecord.fetchOne(db, key: sessionId),
                  session.transcriptionMode == .batch else { return }
            let segments = try RecordingAudioSegmentRecord
                .filter(Column("recordingSessionId") == sessionId)
                .fetchAll(db)
            guard !segments.isEmpty,
                  !segments.contains(where: { [.recording, .finalizing, .purgePending].contains($0.state) }) else {
                return
            }
            let maximumEndOffset = segments.compactMap(\.sessionEndOffsetSeconds).max() ?? 0
            if session.endedAt == nil {
                session = try RecordingSessionCompletionWriter.finish(
                    RecordingSessionCompletionWriter.Request(
                        recordingSessionId: session.id,
                        meetingId: session.meetingId,
                        endedAt: session.startedAt.addingTimeInterval(maximumEndOffset),
                        duration: maximumEndOffset,
                        updatedAt: .now,
                        meetingStatus: nil
                    ),
                    in: db
                )
            }

            let hasFailure = segments.contains(where: { $0.state == .failed })
            let progressRows = try RecordingAudioSourceProgressRecord
                .filter(Column("recordingSessionId") == sessionId)
                .fetchAll(db)
            let durableOffset = progressRows
                .filter(\.isRequired)
                .map(\.durableThroughOffsetSeconds)
                .min() ?? 0
            if hasFailure, session.batchCompletedAt == nil, session.batchDiscardedAt == nil {
                let durableTime = session.startedAt
                    .addingTimeInterval(durableOffset)
                    .formatted(date: .omitted, time: .standard)
                session.batchLastError = L10n.recordingAudioRecoveryIncomplete(durableTime: durableTime)
                session.batchFailureKind = .recordingRecovery
                session.updatedAt = .now
                try session.update(db)
            }
            for var progress in progressRows {
                progress.captureState = hasFailure && progress.failureCode != nil ? .failed : .ended
                progress.updatedAt = .now
                try progress.update(db)
            }
        }
    }

    private func reconcile(segmentId: UUID) async throws -> RecordingAudioSegmentState? {
        let record = try await fetchSegment(id: segmentId)
        let partialURL = try safeURL(relativePath: record.partialRelativePath)
        let finalURL = try safeURL(relativePath: record.finalRelativePath)
        let partialPresence = Self.filePresence(at: partialURL)
        let finalPresence = Self.filePresence(at: finalURL)
        guard partialPresence != .inaccessible, finalPresence != .inaccessible else {
            throw RecordingAudioStoreError.storageUnavailable
        }
        guard partialPresence != .symbolicLink, finalPresence != .symbolicLink else {
            try await fail(segmentId: segmentId, stage: "reconcile", code: "symbolicLink")
            return .failed
        }

        switch record.state {
        case .recording:
            guard partialPresence == .regular, finalPresence == .missing else {
                try await fail(
                    segmentId: segmentId,
                    stage: "reconcileRecording",
                    code: finalPresence == .regular ? "unexpectedFinal" : "missingPartial"
                )
                return .failed
            }
            let readableFrames: Int64
            do {
                readableFrames = try await Task.detached(priority: .utility) {
                    try Self.readableFrameCount(at: partialURL)
                }.value
            } catch RecordingAudioStoreError.integrityMismatch {
                try await fail(segmentId: segmentId, stage: "reconcileRecording", code: "unreadablePartial")
                return .failed
            } catch RecordingAudioStoreError.missingFile {
                try await fail(segmentId: segmentId, stage: "reconcileRecording", code: "missingPartial")
                return .failed
            }
            guard readableFrames > 0 else {
                try await fail(segmentId: segmentId, stage: "reconcileRecording", code: "emptyPartial")
                return .failed
            }
            let endOffset = record.sessionStartOffsetSeconds + Double(readableFrames) / record.sampleRate
            try await markFinalizing(
                segmentId: segmentId,
                sealedFrameCount: readableFrames,
                sessionEndOffsetSeconds: endOffset
            )
            _ = try await finalize(segmentId: segmentId)
            return .ready

        case .finalizing:
            return try await reconcileFinalizing(
                record: record,
                partialURL: partialURL,
                finalURL: finalURL,
                partialPresence: partialPresence,
                finalPresence: finalPresence
            )

        case .ready:
            guard finalPresence == .regular,
                  let expected = Self.expectedIntegrityMetadata(for: record) else {
                if partialPresence == .regular {
                    try await recordIssue(record: record, relativePath: record.partialRelativePath, reason: "unexpectedPartial")
                }
                try await fail(segmentId: segmentId, stage: "reconcileReady", code: "missingOrAmbiguousFile")
                return .failed
            }
            do {
                let actual = try await Task.detached(priority: .utility) {
                    try Self.verify(
                        url: finalURL,
                        expectedFrameCount: expected.frameCount,
                        expectedSampleRate: expected.sampleRate,
                        expectedChannelCount: expected.channelCount
                    )
                }.value
                guard actual == expected else { throw RecordingAudioStoreError.integrityMismatch }
                if partialPresence == .regular {
                    try await recordIssue(
                        record: record,
                        relativePath: record.partialRelativePath,
                        reason: "duplicatePartialPreserved"
                    )
                }
                return nil
            } catch RecordingAudioStoreError.integrityMismatch {
                try await fail(segmentId: segmentId, stage: "reconcileReady", code: "integrityMismatch")
                return .failed
            } catch RecordingAudioStoreError.missingFile {
                try await fail(segmentId: segmentId, stage: "reconcileReady", code: "missingFinal")
                return .failed
            }

        case .purgePending:
            try await purgePendingLocked(
                sessionId: record.recordingSessionId,
                includeAmbiguousFailedFiles: false
            )
            return try await (fetchSegment(id: segmentId)).state

        case .purged, .failed:
            return nil
        }
    }

    private func reconcileFinalizing(
        record: RecordingAudioSegmentRecord,
        partialURL: URL,
        finalURL: URL,
        partialPresence: FilePresence,
        finalPresence: FilePresence
    ) async throws -> RecordingAudioSegmentState {
        guard record.sealedFrameCount != nil else {
            try await fail(segmentId: record.id, stage: "reconcileFinalizing", code: "missingSealedFrames")
            return .failed
        }
        if partialPresence == .regular, finalPresence == .missing {
            _ = try await finalize(segmentId: record.id)
            return .ready
        }
        guard let expected = Self.expectedIntegrityMetadata(for: record) else {
            try await fail(segmentId: record.id, stage: "reconcileFinalizing", code: "missingIntegrityMetadata")
            return .failed
        }
        if partialPresence == .missing, finalPresence == .regular {
            guard try await verify(finalURL, matches: expected) else {
                try await fail(segmentId: record.id, stage: "reconcileFinalizing", code: "integrityMismatch")
                return .failed
            }
            _ = try await markReady(segmentId: record.id)
            return .ready
        }
        guard partialPresence == .regular, finalPresence == .regular else {
            try await fail(segmentId: record.id, stage: "reconcileFinalizing", code: "missingFiles")
            return .failed
        }

        let finalMatches = try await verify(finalURL, matches: expected)
        let partialMatches = try await verify(partialURL, matches: expected)
        if finalMatches {
            try await recordIssue(record: record, relativePath: record.partialRelativePath, reason: "duplicatePartialPreserved")
            _ = try await markReady(segmentId: record.id)
            return .ready
        }
        if partialMatches {
            let recoveredRelativePath = record.finalRelativePath.replacingOccurrences(
                of: ".caf",
                with: ".recovered-\(UUID.v7().uuidString.lowercased()).caf"
            )
            let recoveredURL = try safeURL(relativePath: recoveredRelativePath)
            try await dbQueue.write { db in
                guard var current = try RecordingAudioSegmentRecord.fetchOne(db, key: record.id),
                      current.state == .finalizing else {
                    throw RecordingAudioStoreError.invalidState
                }
                current.finalRelativePath = recoveredRelativePath
                current.updatedAt = .now
                try current.update(db)
            }
            do {
                try Self.publishExclusive(from: partialURL, to: recoveredURL)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recoveredURL.path)
            } catch {
                throw RecordingAudioStoreError.storageUnavailable
            }
            try await recordIssue(record: record, relativePath: record.finalRelativePath, reason: "conflictingFinalPreserved")
            _ = try await markReady(segmentId: record.id)
            return .ready
        }
        try await fail(segmentId: record.id, stage: "reconcileFinalizing", code: "ambiguousFiles")
        return .failed
    }

    private func verify(_ url: URL, matches expected: RecordingAudioIntegrityMetadata) async throws -> Bool {
        do {
            let actual = try await Task.detached(priority: .utility) {
                try Self.verify(
                    url: url,
                    expectedFrameCount: expected.frameCount,
                    expectedSampleRate: expected.sampleRate,
                    expectedChannelCount: expected.channelCount
                )
            }.value
            return actual == expected
        } catch RecordingAudioStoreError.integrityMismatch {
            return false
        } catch {
            throw error
        }
    }

    private func purgePendingLocked(sessionId: UUID, includeAmbiguousFailedFiles: Bool) async throws {
        let records = try await dbQueue.read { db in
            try RecordingAudioSegmentRecord
                .filter(Column("recordingSessionId") == sessionId)
                .filter(Column("state") == RecordingAudioSegmentState.purgePending.rawValue)
                .fetchAll(db)
        }
        for record in records {
            let partialURL = try safeURL(relativePath: record.partialRelativePath)
            let finalURL = try safeURL(relativePath: record.finalRelativePath)
            let partialPresence = Self.filePresence(at: partialURL)
            let finalPresence = Self.filePresence(at: finalURL)
            guard partialPresence != .inaccessible, finalPresence != .inaccessible else {
                throw RecordingAudioStoreError.storageUnavailable
            }
            guard partialPresence != .symbolicLink, finalPresence != .symbolicLink else {
                throw RecordingAudioStoreError.invalidPath
            }
            let partialExists = partialPresence == .regular
            let finalExists = finalPresence == .regular
            var shouldDeletePartial = includeAmbiguousFailedFiles && partialExists
            if partialExists, !includeAmbiguousFailedFiles {
                guard let expected = Self.expectedIntegrityMetadata(for: record) else {
                    try await fail(segmentId: record.id, stage: "purge", code: "ambiguousFiles")
                    throw RecordingAudioStoreError.ambiguousFiles
                }
                let partialMatches = try await verify(partialURL, matches: expected)
                let finalMatches: Bool = if finalExists {
                    try await verify(finalURL, matches: expected)
                } else {
                    true
                }
                guard partialMatches, finalMatches else {
                    try await fail(segmentId: record.id, stage: "purge", code: "ambiguousFiles")
                    throw RecordingAudioStoreError.ambiguousFiles
                }
                shouldDeletePartial = true
            }
            do {
                if finalExists {
                    try removeManagedFile(relativePath: record.finalRelativePath)
                }
                if shouldDeletePartial {
                    try removeManagedFile(relativePath: record.partialRelativePath)
                }
            } catch {
                throw RecordingAudioStoreError.storageUnavailable
            }
            let purgedAt = Date.now
            try await dbQueue.write { db in
                guard var current = try RecordingAudioSegmentRecord.fetchOne(db, key: record.id),
                      current.state == .purgePending else { return }
                current.state = .purged
                current.purgedAt = purgedAt
                current.updatedAt = purgedAt
                try current.update(db)
            }
        }
        try await removePurgedSessionDirectoryIfPossible(sessionId: sessionId)
    }

    private func acquireTemporarySessionLease(sessionId: UUID) async throws -> AdvisoryFileLock {
        guard sessionLeases[sessionId] == nil else {
            throw RecordingAudioStoreError.activeSession
        }
        let meetingId = try await dbQueue.read { db in
            guard let meetingId = try UUID.fetchOne(
                db,
                sql: "SELECT meetingId FROM recording_sessions WHERE id = ?",
                arguments: [sessionId]
            ) else {
                throw RecordingAudioStoreError.missingFile
            }
            return meetingId
        }
        do {
            return try AdvisoryFileLock.acquire(
                at: sessionDirectoryURL(meetingId: meetingId, sessionId: sessionId).appending(path: ".lease")
            )
        } catch AdvisoryFileLockError.alreadyLocked {
            throw RecordingAudioStoreError.activeSession
        } catch {
            throw RecordingAudioStoreError.storageUnavailable
        }
    }

    private func markReady(segmentId: UUID, at finalizedAt: Date = .now) async throws -> RecordingAudioSegmentRecord {
        try await dbQueue.write { db in
            guard var current = try RecordingAudioSegmentRecord.fetchOne(db, key: segmentId),
                  current.state == .finalizing,
                  current.sealedFrameCount != nil,
                  current.byteCount != nil,
                  current.sha256 != nil,
                  current.integrityVerifiedAt != nil else {
                throw RecordingAudioStoreError.invalidState
            }
            current.state = .ready
            current.finalizedAt = finalizedAt
            current.updatedAt = finalizedAt
            try current.update(db)
            try Self.advanceDurabilityCursor(
                sessionId: current.recordingSessionId,
                source: current.source,
                at: finalizedAt,
                in: db
            )
            return current
        }
    }

    private func recordIssue(
        record: RecordingAudioSegmentRecord,
        relativePath: String,
        reason: String,
        at now: Date = .now
    ) async throws {
        try await dbQueue.write { db in
            if var existing = try RecordingAudioReconciliationIssueRecord
                .filter(Column("audioSegmentId") == record.id)
                .filter(Column("relativePath") == relativePath)
                .filter(Column("reason") == reason)
                .filter(Column("resolvedAt") == nil)
                .fetchOne(db) {
                existing.lastObservedAt = now
                try existing.update(db)
            } else {
                try RecordingAudioReconciliationIssueRecord(
                    id: .v7(),
                    recordingSessionId: record.recordingSessionId,
                    audioSegmentId: record.id,
                    relativePath: relativePath,
                    reason: reason,
                    firstObservedAt: now,
                    lastObservedAt: now,
                    resolvedAt: nil
                ).insert(db)
            }
        }
    }

    private func recordOrphans(at now: Date = .now) async throws -> Int {
        let knownPaths = try await dbQueue.read { db in
            let records = try RecordingAudioSegmentRecord.fetchAll(db)
            return Set(records.flatMap { [$0.partialRelativePath, $0.finalRelativePath] })
        }
        let rootURL = managedRootURL
        let orphanPaths = try await Task.detached(priority: .utility) {
            try Self.findOrphanPaths(rootURL: rootURL, knownPaths: knownPaths)
        }.value
        try await dbQueue.write { db in
            for relativePath in orphanPaths {
                if var existing = try RecordingAudioReconciliationIssueRecord
                    .filter(Column("relativePath") == relativePath)
                    .filter(Column("reason") == "orphanFile")
                    .filter(Column("resolvedAt") == nil)
                    .fetchOne(db) {
                    existing.lastObservedAt = now
                    try existing.update(db)
                } else {
                    try RecordingAudioReconciliationIssueRecord(
                        id: .v7(),
                        recordingSessionId: nil,
                        audioSegmentId: nil,
                        relativePath: relativePath,
                        reason: "orphanFile",
                        firstObservedAt: now,
                        lastObservedAt: now,
                        resolvedAt: nil
                    ).insert(db)
                }
            }
        }
        return orphanPaths.count
    }

    private static func findOrphanPaths(rootURL: URL, knownPaths: Set<String>) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var orphanPaths: [String] = []
        let rootPrefix = rootURL.path + "/"
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true,
                  url.pathExtension == "caf",
                  url.path.hasPrefix(rootPrefix) else { continue }
            let relativePath = String(url.path.dropFirst(rootPrefix.count))
            guard !knownPaths.contains(relativePath) else { continue }
            orphanPaths.append(relativePath)
        }
        return orphanPaths
    }

    private func fetchSegment(id: UUID) async throws -> RecordingAudioSegmentRecord {
        try await dbQueue.read { db in
            guard let record = try RecordingAudioSegmentRecord.fetchOne(db, key: id) else {
                throw RecordingAudioStoreError.missingFile
            }
            return record
        }
    }

    private func ensureAvailableCapacity() throws {
        let values = try managedRootURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let capacity = values.volumeAvailableCapacityForImportantUsage,
           capacity < configuration.minimumAvailableCapacity {
            throw RecordingAudioStoreError.diskSpaceLow
        }
    }

    private func sessionDirectoryURL(meetingId: UUID, sessionId: UUID) -> URL {
        managedRootURL
            .appending(path: meetingId.uuidString, directoryHint: .isDirectory)
            .appending(path: sessionId.uuidString, directoryHint: .isDirectory)
    }

    private func safeURL(relativePath: String) throws -> URL {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
            throw RecordingAudioStoreError.invalidPath
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw RecordingAudioStoreError.invalidPath
        }
        let candidate = managedRootURL.appending(path: relativePath).standardizedFileURL
        let rootPrefix = managedRootURL.path.hasSuffix("/") ? managedRootURL.path : managedRootURL.path + "/"
        guard candidate.path.hasPrefix(rootPrefix),
              try !Self.parentPathContainsSymbolicLink(candidate, stoppingAt: managedRootURL) else {
            throw RecordingAudioStoreError.invalidPath
        }
        return candidate
    }

    private static func ensureDirectory(at url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR else {
                throw RecordingAudioStoreError.invalidPath
            }
        }
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw RecordingAudioStoreError.invalidPath
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func repairManagedPermissions(rootURL: URL) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else { return }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values.isDirectory == true {
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            } else if values.isRegularFile == true {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
    }

    private func removeManagedFile(relativePath: String) throws {
        _ = try safeURL(relativePath: relativePath)
        let components = relativePath.split(separator: "/").map(String.init)
        guard let leaf = components.last else { throw RecordingAudioStoreError.invalidPath }
        var descriptor = open(managedRootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw RecordingAudioStoreError.storageUnavailable }
        defer { close(descriptor) }
        for component in components.dropLast() {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard next >= 0 else { throw RecordingAudioStoreError.invalidPath }
            close(descriptor)
            descriptor = next
        }
        guard unlinkat(descriptor, leaf, 0) == 0 else {
            if errno == ENOENT { return }
            throw RecordingAudioStoreError.storageUnavailable
        }
    }

    private func removePurgedSessionDirectoryIfPossible(sessionId: UUID) async throws {
        let context = try await dbQueue.read { db -> (meetingId: UUID, hasUnpurgedSegments: Bool)? in
            guard let meetingId = try UUID.fetchOne(
                db,
                sql: "SELECT meetingId FROM recording_sessions WHERE id = ?",
                arguments: [sessionId]
            ) else { return nil }
            let hasUnpurgedSegments = try RecordingAudioSegmentRecord
                .filter(Column("recordingSessionId") == sessionId)
                .filter(Column("state") != RecordingAudioSegmentState.purged.rawValue)
                .fetchCount(db) > 0
            return (meetingId, hasUnpurgedSegments)
        }
        guard let context, !context.hasUnpurgedSegments else { return }

        let meetingPath = context.meetingId.uuidString
        let sessionPath = "\(meetingPath)/\(sessionId.uuidString)"
        try removeManagedFile(relativePath: "\(sessionPath)/.lease")
        try removeManagedDirectory(relativePath: sessionPath)
        try removeManagedDirectory(relativePath: meetingPath)
    }

    private func removeManagedDirectory(relativePath: String) throws {
        _ = try safeURL(relativePath: "\(relativePath)/placeholder")
        let components = relativePath.split(separator: "/").map(String.init)
        guard let leaf = components.last else { throw RecordingAudioStoreError.invalidPath }
        var descriptor = open(managedRootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw RecordingAudioStoreError.storageUnavailable }
        defer { close(descriptor) }
        for component in components.dropLast() {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard next >= 0 else {
                if errno == ENOENT { return }
                throw RecordingAudioStoreError.invalidPath
            }
            close(descriptor)
            descriptor = next
        }
        guard unlinkat(descriptor, leaf, AT_REMOVEDIR) == 0 else {
            if errno == ENOENT || errno == ENOTEMPTY { return }
            throw RecordingAudioStoreError.storageUnavailable
        }
    }

    private static func parentPathContainsSymbolicLink(_ fileURL: URL, stoppingAt rootURL: URL) throws -> Bool {
        var current = fileURL.deletingLastPathComponent()
        while current.path != rootURL.path {
            var info = stat()
            if lstat(current.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK {
                return true
            }
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { return true }
            current = parent
        }
        return false
    }

    private static func filePresence(at url: URL) -> FilePresence {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            return errno == ENOENT ? .missing : .inaccessible
        }
        if info.st_mode & S_IFMT == S_IFLNK { return .symbolicLink }
        return info.st_mode & S_IFMT == S_IFREG ? .regular : .inaccessible
    }

    private static func publishExclusive(from sourceURL: URL, to destinationURL: URL) throws {
        guard renamex_np(sourceURL.path, destinationURL.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw RecordingAudioStoreError.ambiguousFiles }
            throw RecordingAudioStoreError.storageUnavailable
        }
    }

    private static func readableFrameCount(at url: URL) throws -> Int64 {
        do {
            return try AVAudioFile(forReading: url).length
        } catch let error as CocoaError where [
            .fileReadNoPermission,
            .fileReadNoSuchFile,
        ].contains(error.code) {
            throw error.code == .fileReadNoSuchFile
                ? RecordingAudioStoreError.missingFile
                : RecordingAudioStoreError.storageUnavailable
        } catch {
            throw RecordingAudioStoreError.integrityMismatch
        }
    }

    private static func expectedIntegrityMetadata(
        for record: RecordingAudioSegmentRecord
    ) -> RecordingAudioIntegrityMetadata? {
        guard let frameCount = record.sealedFrameCount,
              let byteCount = record.byteCount,
              let sha256 = record.sha256,
              record.integrityVerifiedAt != nil else { return nil }
        return RecordingAudioIntegrityMetadata(
            frameCount: frameCount,
            sampleRate: record.sampleRate,
            channelCount: record.channelCount,
            byteCount: byteCount,
            sha256: sha256
        )
    }

    private static func hasContiguousSegmentIndices(_ records: [RecordingAudioSegmentRecord]) -> Bool {
        let recordsBySource = Dictionary(grouping: records, by: \.source)
        return recordsBySource.values.allSatisfy { sourceRecords in
            sourceRecords.enumerated().allSatisfy { offset, record in
                record.segmentIndex == offset
            }
        }
    }

    private static func durablyVerify(
        url: URL,
        expectedFrameCount: Int64,
        expectedSampleRate: Double,
        expectedChannelCount: Int
    ) throws -> RecordingAudioIntegrityMetadata {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw RecordingAudioStoreError.missingFile }
        defer { close(descriptor) }
        guard fcntl(descriptor, F_FULLFSYNC) == 0 else {
            throw RecordingAudioStoreError.storageUnavailable
        }
        return try verify(
            url: url,
            expectedFrameCount: expectedFrameCount,
            expectedSampleRate: expectedSampleRate,
            expectedChannelCount: expectedChannelCount
        )
    }

    private static func verify(
        url: URL,
        expectedFrameCount: Int64,
        expectedSampleRate: Double,
        expectedChannelCount: Int
    ) throws -> RecordingAudioIntegrityMetadata {
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch let error as CocoaError where [
            .fileReadNoPermission,
            .fileReadNoSuchFile,
        ].contains(error.code) {
            throw error.code == .fileReadNoSuchFile
                ? RecordingAudioStoreError.missingFile
                : RecordingAudioStoreError.storageUnavailable
        } catch {
            throw RecordingAudioStoreError.integrityMismatch
        }
        guard audioFile.length == expectedFrameCount,
              audioFile.processingFormat.sampleRate == expectedSampleRate,
              Int(audioFile.processingFormat.channelCount) == expectedChannelCount else {
            throw RecordingAudioStoreError.integrityMismatch
        }
        let fileSize: Int64
        let digest: Data
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber else {
                throw RecordingAudioStoreError.storageUnavailable
            }
            fileSize = size.int64Value
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                hasher.update(data: data)
            }
            digest = Data(hasher.finalize())
        } catch let error as RecordingAudioStoreError {
            throw error
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw RecordingAudioStoreError.missingFile
        } catch {
            throw RecordingAudioStoreError.storageUnavailable
        }
        return RecordingAudioIntegrityMetadata(
            frameCount: audioFile.length,
            sampleRate: audioFile.processingFormat.sampleRate,
            channelCount: Int(audioFile.processingFormat.channelCount),
            byteCount: fileSize,
            sha256: digest
        )
    }

    private static func advanceDurabilityCursor(
        sessionId: UUID,
        source: RecordingAudioSource,
        at now: Date,
        in db: Database
    ) throws {
        guard var progress = try RecordingAudioSourceProgressRecord.fetchOne(
            db,
            key: ["recordingSessionId": sessionId, "source": source]
        ) else { return }
        let segments = try RecordingAudioSegmentRecord
            .filter(Column("recordingSessionId") == sessionId)
            .filter(Column("source") == source.rawValue)
            .order(Column("segmentIndex").asc)
            .fetchAll(db)
        var expectedIndex = 0
        var cursor: TimeInterval = 0
        for segment in segments {
            guard segment.segmentIndex == expectedIndex,
                  segment.state == .ready,
                  let endOffset = segment.sessionEndOffsetSeconds else { break }
            if expectedIndex > 0, segment.sessionStartOffsetSeconds > cursor + 0.001 {
                break
            }
            cursor = max(cursor, endOffset)
            expectedIndex += 1
        }
        progress.durableThroughOffsetSeconds = cursor
        progress.lastContiguousReadySegmentIndex = expectedIndex == 0 ? nil : expectedIndex - 1
        progress.updatedAt = now
        try progress.update(db)
    }
}
