import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct BatchLanguageDetectionMigrationTests {
        @Test
        func existingBatchSessionsDefaultToManualLanguageDetection() throws {
            let databaseURL = URL.temporaryDirectory
                .appending(path: UUID.v7().uuidString)
                .appendingPathExtension("sqlite")
            defer { try? FileManager.default.removeItem(at: databaseURL) }

            let queue = try DatabaseQueue(path: databaseURL.path)
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v22_transcriptPagingIndex")
            let session = try insertExistingSession(into: queue)

            let migrated = try AppDatabaseManager(path: databaseURL.path)
            let migratedSession = try migrated.dbQueue.read { db in
                try RecordingSessionRecord.fetchOne(db, key: session.id)
            }
            #expect(migratedSession?.batchLanguageDetectionMode == .manual)
        }

        private func insertExistingSession(into queue: DatabaseQueue) throws -> RecordingSessionRecord {
            let now = Date(timeIntervalSince1970: 1_776_384_000)
            let vault = VaultRecord(id: .v7(), path: "/tmp/vault", name: "Vault", createdAt: now, lastOpenedAt: now)
            let meeting = MeetingRecord(
                id: .v7(),
                vaultId: vault.id,
                projectId: nil,
                name: "Existing",
                status: .transcriptNotFound,
                duration: 30,
                createdAt: now,
                updatedAt: now
            )
            let session = RecordingSessionRecord(
                id: .v7(),
                meetingId: meeting.id,
                startedAt: now,
                endedAt: now.addingTimeInterval(30),
                duration: 30,
                offsetSeconds: 0,
                createdAt: now,
                updatedAt: now,
                transcriptionMode: .batch
            )
            try queue.write { db in
                try vault.insert(db)
                try meeting.insert(db)
                try insertLegacySession(session, into: db)
            }
            return session
        }

        private func insertLegacySession(_ session: RecordingSessionRecord, into database: Database) throws {
            try database.execute(
                sql: """
                INSERT INTO recording_sessions (
                    id, meetingId, startedAt, endedAt, duration, offsetSeconds, createdAt, updatedAt, transcriptionMode
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    session.id,
                    session.meetingId,
                    session.startedAt,
                    session.endedAt,
                    session.duration,
                    session.offsetSeconds,
                    session.createdAt,
                    session.updatedAt,
                    TranscriptionMode.batch.rawValue,
                ]
            )
        }
    }
#endif
