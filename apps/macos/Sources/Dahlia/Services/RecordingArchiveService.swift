import Foundation
import GRDB

/// Reads a recording kept on this Mac as an archive (a Server workspace's recording that moved to a Local workspace) for
/// batch transcription. A recording a Dahlia Server held alone is unavailable.
actor RecordingArchiveService {
    private let dbQueue: any DatabaseWriter
    private let root: URL

    init(dbQueue: any DatabaseWriter, root: URL = BatchAudioStorage.managedRootURL) {
        self.dbQueue = dbQueue
        self.root = root
    }

    private static func checkTarget(_ archive: RecordingArchiveRecord, in db: Database) throws {
        guard archive.connectionId == nil, let current = try RecordingArchiveRecord.fetchOne(db, key: archive.sessionId),
              current.connectionId == nil, current.workspaceId == archive.workspaceId else { throw CancellationError() }
    }

    func withArchivedSegments<T: Sendable>(
        sessionId: UUID,
        operation: @Sendable ([RecordingAudioStore.VerifiedSegment]) async throws -> T
    ) async throws -> T {
        let store = try RecordingAudioStore(dbQueue: dbQueue, managedRootURL: root)
        return try await store.withSessionReadLease(sessionId: sessionId) {
            try await self.readArchivedSegments(sessionId: sessionId, operation: operation)
        }
    }

    private func readArchivedSegments<T: Sendable>(
        sessionId: UUID,
        operation: @Sendable ([RecordingAudioStore.VerifiedSegment]) async throws -> T
    ) async throws -> T {
        let archive = try await dbQueue.read { db -> RecordingArchiveRecord in
            guard let archive = try RecordingArchiveRecord.fetchOne(db, key: sessionId) else { throw RecordingAudioStoreError.missingFile }
            try Self.checkTarget(archive, in: db)
            return archive
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: "dahlia-recording-\(UUID.v7().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        var verified: [RecordingAudioStore.VerifiedSegment] = []
        let selectedLocale = try await dbQueue.read { db -> String? in
            let session = try RecordingSessionRecord.fetchOne(db, key: sessionId)
            return session?.batchLanguageDetectionMode == .manual ? session?.batchSelectedLocaleIdentifier : nil
        }
        let prepared = try SyncJSON.decoder.decode([String: RecordingArchiveEncoder.Prepared].self, from: Data(archive.preparedJSON.utf8))
        let audioFiles = prepared.mapValues { file in
            RecordingArchivedAudio(
                contentType: "audio/mp4",
                size: file.size,
                checksum: file.checksum,
                contentURL: "",
                manifest: file.manifest
            )
        }
        for (name, audio) in audioFiles.sorted(by: { $0.key < $1.key }) {
            guard let source = RecordingAudioSource(audioSource: name) else { throw RecordingAudioStoreError.invalidState }
            guard let file = prepared[name], let local = BatchAudioStorage.safeURL(baseURL: root, relativePath: file.relativePath),
                  try RecordingArchiveEncoder.checksum(local) == file.checksum else { throw RecordingAudioStoreError.integrityMismatch }
            let input = directory.appending(path: "\(name).m4a")
            try FileManager.default.copyItem(at: local, to: input)
            defer { try? FileManager.default.removeItem(at: input) }
            let output = directory.appending(path: "\(name).caf")
            try RecordingArchiveEncoder.decode(input, to: output, manifest: audio.manifest)
            let id = UUID.v7()
            let now = Date.now
            let segment = RecordingAudioSegmentRecord(
                id: id, recordingSessionId: sessionId, source: source, segmentIndex: 1, generationId: .v7(), state: .ready,
                partialRelativePath: "", finalRelativePath: "", sampleRate: Double(audio.manifest.sampleRate), channelCount: 1,
                sealedFrameCount: audio.manifest.frameCount, sessionStartOffsetSeconds: 0,
                sessionEndOffsetSeconds: Double(audio.manifest.frameCount) / Double(audio.manifest.sampleRate),
                byteCount: nil, sha256: nil, finalizationStartedAt: nil, integrityVerifiedAt: now, finalizedAt: now,
                purgeRequestedAt: nil, purgedAt: nil, failureStage: nil, failureCode: nil, createdAt: now, updatedAt: now
            )
            let ranges = audio.manifest.ranges.map {
                RecordingAudioSegmentRangeRecord(
                    id: .v7(),
                    audioSegmentId: id,
                    startFrame: $0.startFrame,
                    frameCount: $0.frameCount,
                    sessionOffsetSeconds: $0.sessionOffsetSeconds,
                    localeIdentifier: selectedLocale ?? $0.localeIdentifier,
                    createdAt: now,
                    updatedAt: now
                )
            }
            verified.append(.init(segment: segment, url: output, ranges: ranges))
        }
        guard !verified.isEmpty else { throw RecordingAudioStoreError.missingFile }
        try await dbQueue.read { try Self.checkTarget(archive, in: $0) }
        return try await operation(verified)
    }

}
