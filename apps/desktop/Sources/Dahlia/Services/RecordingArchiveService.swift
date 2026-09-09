import Foundation
import GRDB

/// Durable archive preparation runs in the sync worker's idle lane, never in recording stop/drain.
actor RecordingArchiveService {
    private let dbQueue: DatabaseQueue
    private let api: SyncAPIClient
    private let root: URL
    private var isProcessing = false

    init(dbQueue: DatabaseQueue, api: SyncAPIClient = SyncAPIClient(session: .shared), root: URL = BatchAudioStorage.managedRootURL) {
        self.dbQueue = dbQueue
        self.api = api
        self.root = root
    }

    private struct Target: Sendable {
        let archive: RecordingArchiveRecord
        let origin: URL?
    }

    private struct UploadResult: Decodable {
        let id: Int
        let size: Int64
        let checksum: String
    }

    private struct Commit: Codable {
        let source: String
        let checksum: String
        let manifest: RecordingArchiveManifest
    }

    func runNext(localOnly: Bool = false) async throws {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }
        let target = try await dbQueue.read { db -> Target? in
            let now = Date.now
            let row = try Row.fetchOne(db, sql: """
            SELECT a.*, c.origin FROM recording_archives a
            JOIN recording_sessions s ON s.id = a.sessionId
            JOIN vaults v ON v.id = a.vaultId
            LEFT JOIN dahlia_account_connections c ON c.id = a.connectionId
            WHERE (a.state IN ('pending', 'failed', 'syncing')
                   OR a.state = 'saved' AND EXISTS (SELECT 1 FROM recording_audio_segments
                       WHERE recordingSessionId = a.sessionId AND state IN ('ready', 'purgePending')))
              AND (a.retryAt IS NULL OR a.retryAt <= ?)
              AND ((a.connectionId IS NULL AND v.accountConnectionId IS NULL)
                   OR (v.accountConnectionId = a.connectionId AND v.syncConfirmedConnectionId = a.connectionId))
              AND (a.connectionId IS NULL) = ?
              AND v.syncRecoveryState IS NULL AND COALESCE(v.syncRole, 'owner') = 'owner'
              AND s.endedAt IS NOT NULL AND s.batchDiscardedAt IS NULL
              AND NOT EXISTS (SELECT 1 FROM recording_audio_segments WHERE recordingSessionId = a.sessionId AND state NOT IN ('ready', 'purgePending', 'purged'))
              AND NOT EXISTS (SELECT 1 FROM sync_transactions WHERE vaultId = a.vaultId)
              AND NOT EXISTS (SELECT 1 FROM recording_audio_segments WHERE state IN ('recording', 'finalizing'))
              AND NOT EXISTS (SELECT 1 FROM recording_sessions WHERE batchLastAttemptAt > COALESCE(batchCompletedAt, 0)
                              AND batchLastError IS NULL AND batchDiscardedAt IS NULL)
            ORDER BY s.startedAt LIMIT 1
            """, arguments: [now, localOnly])
            guard let row else { return nil }
            let origin: String? = row["origin"]
            return try Target(archive: RecordingArchiveRecord(row: row), origin: origin.flatMap(URL.init(string:)))
        }
        guard let target else { return }
        let work = Task(priority: .utility) { try await self.process(target) }
        let observation = ValueObservation.tracking { db in
            try Bool.fetchOne(db, sql: """
            SELECT EXISTS (SELECT 1 FROM recording_audio_segments WHERE state IN ('recording', 'finalizing'))
                OR EXISTS (SELECT 1 FROM recording_sessions WHERE batchLastAttemptAt > COALESCE(batchCompletedAt, 0)
                           AND batchLastError IS NULL AND batchDiscardedAt IS NULL)
            """) ?? false
        }.removeDuplicates().start(
            in: dbQueue,
            scheduling: .async(onQueue: .global(qos: .utility)),
            onError: { _ in work.cancel() },
            onChange: { busy in
                if busy { work.cancel() }
            }
        )
        defer { observation.cancel() }
        do {
            try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        } catch is CancellationError {
            if Task.isCancelled { throw CancellationError() }
        } catch {
            let code = (error as? SyncHTTPError).map { "http_\($0.status)" } ?? "archive_failed"
            try await dbQueue.write { db in
                try db.execute(sql: """
                UPDATE recording_archives SET state = 'failed', failureCode = ?, retryAt = ?
                WHERE sessionId = ? AND connectionId IS ?
                """, arguments: [code, Date.now.addingTimeInterval(60), target.archive.sessionId, target.archive.connectionId])
            }
        }
    }

    private func process(_ target: Target) async throws {
        let archive = target.archive
        let store = try RecordingAudioStore(dbQueue: dbQueue, managedRootURL: root)
        let cleanupStarted = try await dbQueue.read { db in
            try Self.checkTarget(archive, in: db)
            return try RecordingAudioSegmentRecord.filter(Column("recordingSessionId") == archive.sessionId)
                .filter([RecordingAudioSegmentState.purgePending.rawValue, RecordingAudioSegmentState.purged.rawValue].contains(Column("state")))
                .fetchCount(db) > 0
        }
        if archive.verifiedAt != nil, cleanupStarted {
            try await purgeSources(archive, store: store)
            return
        }
        if let origin = target.origin, let connectionId = archive.connectionId {
            let data = try await api.data(
                for: URLRequest(url: origin.appending(path: "api/v1/capabilities")),
                connectionId: connectionId,
                maximumBytes: 64 * 1024
            )
            guard try SyncJSON.decoder.decode(ServerCapabilities.self, from: data).recordingArchive?.version == 1 else {
                throw SyncHTTPError(status: 426, body: Data())
            }
        }
        var prepared = try SyncJSON.decoder.decode([String: RecordingArchiveEncoder.Prepared].self, from: Data(archive.preparedJSON.utf8))
        if prepared.isEmpty {
            let root = root
            prepared = try await store.withVerifiedTranscribableSegments(sessionId: archive.sessionId) { verified in
                guard verified.allSatisfy({ $0.segment.state == .ready }) else { throw RecordingAudioStoreError.invalidState }
                let encoding = Task.detached(priority: .utility) {
                    var files: [String: RecordingArchiveEncoder.Prepared] = [:]
                    for source in [RecordingAudioSource.microphone, .system] {
                        let segments = verified.filter { $0.segment.source == source }
                        guard !segments.isEmpty else { continue }
                        files[source.audioSource] = try RecordingArchiveEncoder.encode(
                            segments, relativePath: "archives/\(archive.sessionId.uuidString.lowercased())/audio_\(source.audioSource).m4a",
                            root: root
                        )
                    }
                    return files
                }
                return try await withTaskCancellationHandler { try await encoding.value } onCancel: { encoding.cancel() }
            }
            guard !prepared.isEmpty else { throw RecordingAudioStoreError.missingFile }
            let json = try String(decoding: SyncJSON.encoder.encode(prepared), as: UTF8.self)
            try await dbQueue.write { db in
                try Self.checkTarget(archive, in: db)
                try db.execute(sql: "UPDATE recording_archives SET preparedJSON = ? WHERE sessionId = ?", arguments: [json, archive.sessionId])
            }
        }
        if archive.connectionId == nil {
            for file in prepared.values {
                guard let url = BatchAudioStorage.safeURL(baseURL: root, relativePath: file.relativePath),
                      try RecordingArchiveEncoder.checksum(url) == file.checksum else { throw RecordingAudioStoreError.integrityMismatch }
                try RecordingArchiveEncoder.validate(url, manifest: file.manifest)
            }
            try await markSavedAndPurgeSources(archive, store: store)
            return
        }
        guard let origin = target.origin, let connectionId = archive.connectionId else { throw RecordingAudioStoreError.storageUnavailable }
        let canonical = try archive.audio
        var commits: [Commit] = []
        for (source, file) in prepared.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            try await dbQueue.read { try Self.checkTarget(archive, in: $0) }
            guard let url = BatchAudioStorage.safeURL(baseURL: root, relativePath: file.relativePath),
                  try RecordingArchiveEncoder.checksum(url) == file.checksum else { throw RecordingAudioStoreError.integrityMismatch }
            if canonical[source]?.checksum == file.checksum { continue }
            let result = try await upload(file, source: source, archive: archive, origin: origin, connectionId: connectionId)
            commits.append(Commit(source: source, checksum: result.checksum, manifest: file.manifest))
        }
        if !commits.isEmpty {
            let payloads = try commits.map { try SyncJSON.encoder.encode($0) }
            try await dbQueue.write { db in
                try Self.checkTarget(archive, in: db)
                for payload in payloads {
                    try SyncTransactionRecorder.record(vaultId: archive.vaultId, operations: [
                        SyncOperationDraft(entity: .recording, action: .upsert, entityId: archive.sessionId, payloadJSON: payload),
                    ], in: db)
                }
                try db.execute(
                    sql: "UPDATE recording_archives SET state = 'syncing', failureCode = NULL, retryAt = NULL WHERE sessionId = ?",
                    arguments: [archive.sessionId]
                )
            }
            return
        }
        for (source, file) in prepared {
            guard let audio = canonical[source] else { throw RecordingAudioStoreError.invalidState }
            let url = try await download(audio, archive: archive, source: source, origin: origin)
            defer { try? FileManager.default.removeItem(at: url) }
            guard try RecordingArchiveEncoder.checksum(url) == file.checksum else { throw RecordingAudioStoreError.integrityMismatch }
            try RecordingArchiveEncoder.validate(url, manifest: file.manifest)
        }
        try await markSavedAndPurgeSources(archive, store: store)
    }

    private func markSavedAndPurgeSources(_ archive: RecordingArchiveRecord, store: RecordingAudioStore) async throws {
        try await dbQueue.write { db in
            try Self.checkTarget(archive, in: db)
            try db.execute(
                sql: "UPDATE recording_archives SET state = 'saved', verifiedAt = ?, failureCode = NULL, retryAt = NULL WHERE sessionId = ?",
                arguments: [Date.now, archive.sessionId]
            )
        }
        try await purgeSources(archive, store: store)
    }

    private func purgeSources(_ archive: RecordingArchiveRecord, store: RecordingAudioStore) async throws {
        var failed = false
        do {
            try await store.requestPurge(sessionId: archive.sessionId)
        } catch {
            failed = true
        }
        // Source retirement is committed: cleanup failures cannot invalidate the verified archive.
        let retryAt: Date? = failed ? Date.now.addingTimeInterval(60) : nil
        let failureCode: String? = failed ? "source_purge_failed" : nil
        try await dbQueue.write { db in
            try Self.checkTarget(archive, in: db)
            try db.execute(
                sql: "UPDATE recording_archives SET state = 'saved', failureCode = ?, retryAt = ? WHERE sessionId = ?",
                arguments: [failureCode, retryAt, archive.sessionId]
            )
        }
    }

    private func upload(
        _ file: RecordingArchiveEncoder.Prepared,
        source: String,
        archive: RecordingArchiveRecord,
        origin: URL,
        connectionId: UUID
    ) async throws -> UploadResult {
        guard ["mic", "system"].contains(source),
              let url = BatchAudioStorage.safeURL(baseURL: root, relativePath: file.relativePath),
              try RecordingArchiveEncoder.checksum(url) == file.checksum else { throw RecordingAudioStoreError.integrityMismatch }
        var components = URLComponents(
            url: origin.appending(path: "api/v1/meetings/\(archive.meetingId.uuidString.lowercased())/recordings"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "sessionId", value: archive.sessionId.uuidString.lowercased()),
            URLQueryItem(name: "source", value: source),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        request.setValue(String(file.size), forHTTPHeaderField: "Content-Length")
        let result = try await SyncJSON.decoder.decode(UploadResult.self, from: api.upload(request, from: url, connectionId: connectionId))
        guard result.checksum == file.checksum, result.size == file.size else { throw RecordingAudioStoreError.integrityMismatch }
        return result
    }

    /// Refresh expired staging before replaying the unchanged durable transaction.
    func stage(sessionId: UUID, payload: Data, origin: URL, connectionId: UUID) async throws {
        let archive = try await dbQueue.read { db -> RecordingArchiveRecord in
            guard let archive = try RecordingArchiveRecord.fetchOne(db, key: sessionId),
                  archive.connectionId == connectionId else { throw RecordingAudioStoreError.missingFile }
            try Self.checkTarget(archive, in: db)
            return archive
        }
        let commit = try SyncJSON.decoder.decode(Commit.self, from: payload)
        let prepared = try SyncJSON.decoder.decode([String: RecordingArchiveEncoder.Prepared].self, from: Data(archive.preparedJSON.utf8))
        guard let file = prepared[commit.source], file.checksum == commit.checksum else { throw RecordingAudioStoreError.integrityMismatch }
        _ = try await upload(file, source: commit.source, archive: archive, origin: origin, connectionId: connectionId)
    }

    private static func checkTarget(_ archive: RecordingArchiveRecord, in db: Database) throws {
        guard let current = try RecordingArchiveRecord.fetchOne(db, key: archive.sessionId), current.connectionId == archive.connectionId,
              let vault = try VaultRecord.fetchOne(db, key: archive.vaultId), vault.accountConnectionId == archive.connectionId,
              archive.connectionId == nil || vault.syncConfirmedConnectionId == archive.connectionId, vault.syncRecoveryState == nil,
              vault.allowsCanonicalEdits else { throw CancellationError() }
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
        let target = try await dbQueue.read { db -> Target in
            guard let archive = try RecordingArchiveRecord.fetchOne(db, key: sessionId) else { throw RecordingAudioStoreError.missingFile }
            try Self.checkTarget(archive, in: db)
            if archive.connectionId == nil { return Target(archive: archive, origin: nil) }
            guard let originString = try String.fetchOne(
                db,
                sql: "SELECT origin FROM dahlia_account_connections WHERE id = ?",
                arguments: [archive.connectionId]
            ),
                let origin = URL(string: originString) else { throw RecordingAudioStoreError.storageUnavailable }
            return Target(archive: archive, origin: origin)
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: "dahlia-recording-\(UUID.v7().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        var verified: [RecordingAudioStore.VerifiedSegment] = []
        let selectedLocale = try await dbQueue.read { db -> String? in
            let session = try RecordingSessionRecord.fetchOne(db, key: sessionId)
            return session?.batchLanguageDetectionMode == .manual ? session?.batchSelectedLocaleIdentifier : nil
        }
        let prepared = try SyncJSON.decoder.decode([String: RecordingArchiveEncoder.Prepared].self, from: Data(target.archive.preparedJSON.utf8))
        let localAudio = prepared.mapValues { file in
            RecordingArchivedAudio(
                contentType: "audio/mp4",
                size: file.size,
                checksum: file.checksum,
                contentURL: "",
                manifest: file.manifest
            )
        }
        let audioFiles = try target.archive.connectionId == nil ? localAudio : target.archive.audio
        for (name, audio) in audioFiles.sorted(by: { $0.key < $1.key }) {
            guard let source = RecordingAudioSource(audioSource: name) else { throw RecordingAudioStoreError.invalidState }
            let input: URL
            if let origin = target.origin {
                input = try await download(audio, archive: target.archive, source: name, origin: origin)
            } else {
                guard let file = prepared[name], let local = BatchAudioStorage.safeURL(baseURL: root, relativePath: file.relativePath),
                      try RecordingArchiveEncoder.checksum(local) == file.checksum else { throw RecordingAudioStoreError.integrityMismatch }
                input = directory.appending(path: "\(name).m4a")
                try FileManager.default.copyItem(at: local, to: input)
            }
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
        try await dbQueue.read { try Self.checkTarget(target.archive, in: $0) }
        return try await operation(verified)
    }

    private func download(_ audio: RecordingArchivedAudio, archive: RecordingArchiveRecord, source: String, origin: URL) async throws -> URL {
        guard let connectionId = archive.connectionId, ["mic", "system"].contains(source), let number = archive.number, number > 0,
              audio.contentType == "audio/mp4", audio.size > 0, audio.size <= 1024 * 1024 * 1024 else { throw RecordingAudioStoreError.invalidState }
        let url = origin.appending(path: "api/v1/meetings/\(archive.meetingId.uuidString.lowercased())/recordings/\(number)/audio/\(source)")
        let downloaded = try await api.download(URLRequest(url: url), connectionId: connectionId, expectedSize: audio.size)
        do {
            guard try RecordingArchiveEncoder.checksum(downloaded) == audio.checksum else { throw RecordingAudioStoreError.integrityMismatch }
            return downloaded
        } catch {
            try? FileManager.default.removeItem(at: downloaded)
            throw error
        }
    }
}
