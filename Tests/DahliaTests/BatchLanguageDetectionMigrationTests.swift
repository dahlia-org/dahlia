import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct BatchLanguageDetectionMigrationTests {
        @Test
        func v22BatchSessionsDefaultToManualAndBackfillSelectedLocale() throws {
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
            #expect(migratedSession?.batchSelectedLocaleIdentifier == "en_GB")
            #expect(migratedSession?.batchAutomaticLanguageCandidatesJSON == nil)
        }

        @Test
        func legacyDevelopmentV23AddsOnlyMissingSelectedLocaleColumn() throws {
            let databaseURL = URL.temporaryDirectory
                .appending(path: UUID.v7().uuidString)
                .appendingPathExtension("sqlite")
            defer { try? FileManager.default.removeItem(at: databaseURL) }

            let queue = try DatabaseQueue(path: databaseURL.path)
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v22_transcriptPagingIndex")
            let session = try insertExistingSession(into: queue)
            try queue.write { db in
                try db.alter(table: "recording_sessions") { table in
                    table.add(column: "batchLanguageDetectionMode", .text)
                        .notNull()
                        .defaults(to: BatchLanguageDetectionMode.manual.rawValue)
                }
                try db.execute(
                    sql: "UPDATE recording_sessions SET batchLanguageDetectionMode = ? WHERE id = ?",
                    arguments: [BatchLanguageDetectionMode.automatic.rawValue, session.id]
                )
                try db.execute(
                    sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                    arguments: ["v23_batchLanguageDetectionMode"]
                )
            }

            let migrated = try AppDatabaseManager(path: databaseURL.path)
            let result = try migrated.dbQueue.read { db in
                try (
                    RecordingSessionRecord.fetchOne(db, key: session.id),
                    String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('recording_sessions')")
                )
            }
            #expect(result.0?.batchLanguageDetectionMode == .automatic)
            #expect(result.0?.batchSelectedLocaleIdentifier == "en_GB")
            #expect(result.0?.batchAutomaticLanguageCandidatesJSON == nil)
            #expect(result.1.filter { $0 == "batchLanguageDetectionMode" }.count == 1)
            #expect(result.1.filter { $0 == "batchSelectedLocaleIdentifier" }.count == 1)
            #expect(result.1.filter { $0 == "batchAutomaticLanguageCandidatesJSON" }.count == 1)
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
                try insertLegacyAudioRanges(for: session, at: now, into: db)
            }
            return session
        }

        private func insertLegacyAudioRanges(
            for session: RecordingSessionRecord,
            at now: Date,
            into database: Database
        ) throws {
            for (segmentIndex, localeIdentifier) in [(1, "ja_JP"), (0, "en_GB")] {
                let segmentId = UUID.v7()
                let path = "recordings/\(segmentId.uuidString).caf"
                try database.execute(
                    sql: """
                    INSERT INTO recording_audio_segments (
                        id, recordingSessionId, source, segmentIndex, generationId, state,
                        partialRelativePath, finalRelativePath, sampleRate, channelCount,
                        sessionStartOffsetSeconds, createdAt, updatedAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        segmentId, session.id, RecordingAudioSource.microphone.rawValue, segmentIndex, UUID.v7(),
                        RecordingAudioSegmentState.ready.rawValue, path + ".partial", path, 16000, 1,
                        Double(segmentIndex * 30), now, now,
                    ]
                )
                try database.execute(
                    sql: """
                    INSERT INTO recording_audio_segment_ranges (
                        id, audioSegmentId, startFrame, frameCount, sessionOffsetSeconds,
                        localeIdentifier, createdAt, updatedAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        UUID.v7(), segmentId, 0, 480_000, Double(segmentIndex * 30), localeIdentifier, now, now,
                    ]
                )
            }
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
