@preconcurrency import AVFoundation
import Foundation
import GRDB

/// クラッシュ後のpartial CAF確定と、完了後に残った音声の移管・掃除を行う。
enum BatchTranscriptionRecoveryService {
    private struct RecoveryJob {
        let session: RecordingSessionRecord
        let vaultURL: URL
        let files: [RecordingAudioFileRecord]
        let rangesByFileId: [UUID: [RecordingAudioRangeRecord]]
    }

    private struct CompletedAudioJob {
        let session: RecordingSessionRecord
        let vaultURL: URL
        let files: [RecordingAudioFileRecord]
    }

    static func recoverAudioMetadataIfNeeded(
        sessionId: UUID,
        dbQueue: DatabaseQueue,
        managedRootURL: URL = BatchAudioStorage.managedRootURL
    ) throws {
        let job = try fetchJob(sessionId: sessionId, dbQueue: dbQueue)
        var maximumDuration: TimeInterval = 0
        for file in job.files {
            let duration = try recoverAudioFileMetadata(
                file: file,
                ranges: job.rangesByFileId[file.id] ?? [],
                vaultURL: job.vaultURL,
                managedRootURL: managedRootURL,
                dbQueue: dbQueue
            )
            maximumDuration = max(maximumDuration, duration)
        }

        if job.session.endedAt == nil {
            guard maximumDuration > 0 else {
                throw BatchSpeechTranscriberError.invalidAudioRange
            }
            let endedAt = job.session.startedAt.addingTimeInterval(maximumDuration)
            try dbQueue.write { db in
                let updatedAt = Date.now
                _ = try RecordingSessionCompletionWriter.finish(
                    RecordingSessionCompletionWriter.Request(
                        recordingSessionId: job.session.id,
                        meetingId: job.session.meetingId,
                        endedAt: endedAt,
                        duration: maximumDuration,
                        updatedAt: updatedAt,
                        meetingStatus: nil
                    ),
                    in: db
                )
            }
        }
    }

    private static func recoverAudioFileMetadata(
        file originalFile: RecordingAudioFileRecord,
        ranges originalRanges: [RecordingAudioRangeRecord],
        vaultURL: URL,
        managedRootURL: URL,
        dbQueue: DatabaseQueue
    ) throws -> TimeInterval {
        var file = originalFile
        guard let audioURL = BatchAudioStorage.existingURL(
            for: file,
            managedRootURL: managedRootURL,
            vaultURL: vaultURL
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let frameLength = try AVAudioFile(forReading: audioURL).length
        guard frameLength > 0 else {
            throw BatchSpeechTranscriberError.invalidAudioRange
        }

        if audioURL.lastPathComponent.hasSuffix(".partial.caf") {
            let finalURL = BatchAudioStorage.finalURL(
                for: file,
                managedRootURL: managedRootURL,
                vaultURL: vaultURL
            )
            if !FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.moveItem(at: audioURL, to: finalURL)
            }
        }

        let now = Date.now
        file.totalFrameCount = frameLength
        file.finalizedAt = file.finalizedAt ?? now
        file.updatedAt = now
        var ranges = originalRanges
        for index in ranges.indices where ranges[index].frameCount == nil {
            ranges[index].frameCount = max(0, frameLength - ranges[index].startFrame)
            ranges[index].updatedAt = now
        }
        try dbQueue.write { db in
            try file.update(db)
            for range in ranges {
                try range.update(db)
            }
        }
        return ranges.reduce(0) { maximumDuration, range in
            let duration = Double(range.frameCount ?? 0) / file.sampleRate
            return max(maximumDuration, range.sessionOffsetSeconds + duration)
        }
    }

    static func reconcileCompletedAudioFiles(
        dbQueue: DatabaseQueue,
        managedRootURL: URL = BatchAudioStorage.managedRootURL
    ) {
        let jobs: [CompletedAudioJob]
        do {
            jobs = try fetchCompletedAudioJobs(dbQueue: dbQueue)
        } catch {
            ErrorReportingService.capture(error, context: ["source": "batchAudioRecovery"])
            return
        }

        for job in jobs {
            guard job.session.retainAudioAfterBatch else {
                BatchAudioStorage.removeFiles(
                    job.files,
                    managedRootURL: managedRootURL,
                    vaultURL: job.vaultURL
                )
                continue
            }
            do {
                try BatchAudioRetentionService.retainCompletedAudio(
                    sessionId: job.session.id,
                    dbQueue: dbQueue,
                    managedRootURL: managedRootURL
                )
            } catch {
                ErrorReportingService.capture(error, context: ["source": "batchAudioRetentionRecovery"])
            }
        }
    }

    private static func fetchCompletedAudioJobs(dbQueue: DatabaseQueue) throws -> [CompletedAudioJob] {
        try dbQueue.read { db in
            let sessions = try RecordingSessionRecord
                .filter(Column("transcriptionMode") == TranscriptionMode.batch.rawValue)
                .filter(Column("batchCompletedAt") != nil)
                .fetchAll(db)
            return try sessions.map { session in
                guard let meeting = try MeetingRecord.fetchOne(db, key: session.meetingId),
                      let vault = try VaultRecord.fetchOne(db, key: meeting.vaultId) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let files = try RecordingAudioFileRecord
                    .filter(Column("recordingSessionId") == session.id)
                    .fetchAll(db)
                return CompletedAudioJob(session: session, vaultURL: vault.url, files: files)
            }
        }
    }

    private static func fetchJob(sessionId: UUID, dbQueue: DatabaseQueue) throws -> RecoveryJob {
        try dbQueue.read { db in
            guard let session = try RecordingSessionRecord.fetchOne(db, key: sessionId),
                  let meeting = try MeetingRecord.fetchOne(db, key: session.meetingId),
                  let vault = try VaultRecord.fetchOne(db, key: meeting.vaultId) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let files = try RecordingAudioFileRecord
                .filter(Column("recordingSessionId") == sessionId)
                .fetchAll(db)
            guard !files.isEmpty else {
                throw CocoaError(.fileNoSuchFile)
            }
            var rangesByFileId: [UUID: [RecordingAudioRangeRecord]] = [:]
            for file in files {
                rangesByFileId[file.id] = try RecordingAudioRangeRecord
                    .filter(Column("audioFileId") == file.id)
                    .order(Column("startFrame").asc)
                    .fetchAll(db)
            }
            return RecoveryJob(
                session: session,
                vaultURL: vault.url,
                files: files,
                rangesByFileId: rangesByFileId
            )
        }
    }
}
