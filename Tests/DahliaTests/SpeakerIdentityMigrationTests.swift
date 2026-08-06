import DahliaRuntimeSupport
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct SpeakerIdentityMigrationTests {
        @Test
        func upgradesV33PreservingMeetingsTranscriptsAndContacts() throws {
            let url = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-speaker-v33-\(UUID.v7())")
                .appendingPathExtension("sqlite")
            defer { try? FileManager.default.removeItem(at: url) }
            let queue = try DatabaseQueue(path: url.path)
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v33_sharedOrganizationDomains")
            let ids = try insertLegacyRows(in: queue)

            let migrated = try AppDatabaseManager(path: url.path)
            let preserved = try migrated.dbQueue.read { db in
                try (
                    MeetingRecord.fetchOne(db, key: ids.meetingId),
                    String.fetchOne(
                        db,
                        sql: "SELECT text FROM transcript_segments WHERE id = ?",
                        arguments: [ids.transcriptId]
                    ),
                    ContactRecord.fetchOne(db, key: ids.contactId),
                    String.fetchOne(
                        db,
                        sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1"
                    )
                )
            }

            #expect(preserved.0?.name == "Preserved meeting")
            #expect(preserved.1 == "Preserved transcript")
            #expect(preserved.2?.email == "person@example.com")
            #expect(preserved.3 == "v34_speakerIdentity")
        }

        @Test
        func emptyDatabaseAppliesAllMigrationsAndCalibrationRequiredPolicy() throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let result = try database.dbQueue.read { db in
                try (
                    AppDatabaseManager.hasExpectedCurrentSchema(db),
                    SpeakerMatchPolicyRecord.fetchOne(db, key: 1),
                    String.fetchAll(
                        db,
                        sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'speaker_%' ORDER BY name"
                    )
                )
            }

            #expect(result.0)
            #expect(result.1?.formatVersion == SpeakerMatchPolicy.formatVersion)
            #expect(result.1?.state == .calibrationRequired)
            #expect(result.1?.minimumSimilarity == nil)
            #expect(result.1?.minimumMargin == nil)
            #expect(result.2.count == 8)
        }

        @Test
        // swiftlint:disable:next function_body_length
        func schemaEnforcesNullableForeignKeysCascadesUniquenessAndPagingIndex() throws {
            let fixture = try MigrationFixture()
            try fixture.database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE transcript_segments SET meetingSpeakerId = ? WHERE id = ?",
                    arguments: [fixture.meetingSpeakerId, fixture.transcriptId]
                )
                #expect(throws: (any Error).self) {
                    try SpeakerAnalysisRecord(
                        id: .v7(),
                        recordingSessionId: fixture.sessionId,
                        audioSource: .microphone,
                        embeddingSpaceId: fixture.spaceId,
                        state: .succeeded,
                        failureReason: nil,
                        createdAt: .now,
                        updatedAt: .now
                    ).insert(db)
                }
                #expect(throws: (any Error).self) {
                    try SpeakerEmbeddingSpaceRecord(
                        id: .v7(),
                        space: MigrationFixture.space,
                        createdAt: .now
                    ).insert(db)
                }
                let speaker = try #require(try MeetingSpeakerRecord.fetchOne(db, key: fixture.meetingSpeakerId))
                #expect(throws: (any Error).self) {
                    try MeetingSpeakerRecord(
                        id: .v7(),
                        analysisId: speaker.analysisId,
                        localSpeakerId: speaker.localSpeakerId,
                        representative: speaker.representative,
                        representativeQuality: 1,
                        representativeSource: .diarization,
                        profileUpdateEligible: true,
                        revision: 1,
                        createdAt: .now,
                        updatedAt: .now
                    ).insert(db)
                }
                #expect(throws: (any Error).self) {
                    try MeetingSpeakerExemplarRecord(
                        meetingSpeakerId: fixture.meetingSpeakerId,
                        ordinal: 3,
                        embedding: speaker.representative,
                        quality: 1
                    ).insert(db)
                }
                let profile = SpeakerProfileRecord(
                    id: .v7(),
                    vaultId: fixture.vaultId,
                    contactId: fixture.contactId,
                    embeddingSpaceId: fixture.spaceId,
                    representative: speaker.representative,
                    contributingMeetingCount: 1,
                    createdAt: .now,
                    updatedAt: .now
                )
                try profile.insert(db)
                #expect(throws: (any Error).self) {
                    try SpeakerProfileRecord(
                        id: .v7(),
                        vaultId: fixture.vaultId,
                        contactId: fixture.contactId,
                        embeddingSpaceId: fixture.spaceId,
                        representative: speaker.representative,
                        contributingMeetingCount: 1,
                        createdAt: .now,
                        updatedAt: .now
                    ).insert(db)
                }
                #expect(throws: (any Error).self) {
                    try SpeakerProfileExemplarRecord(
                        profileId: profile.id,
                        ordinal: 5,
                        meetingSpeakerId: fixture.meetingSpeakerId,
                        embedding: speaker.representative,
                        quality: 1
                    ).insert(db)
                }
                _ = try MeetingSpeakerRecord.deleteOne(db, key: fixture.meetingSpeakerId)
                let nullableSpeakerId = try UUID.fetchOne(
                    db,
                    sql: "SELECT meetingSpeakerId FROM transcript_segments WHERE id = ?",
                    arguments: [fixture.transcriptId]
                )
                #expect(nullableSpeakerId == nil)

                let indexColumns = try String.fetchAll(
                    db,
                    sql: """
                    SELECT name FROM pragma_index_info('transcript_segments_on_meetingSpeakerId_startTime_id')
                    ORDER BY seqno
                    """
                )
                #expect(indexColumns == ["meetingSpeakerId", "startTime", "id"])

                _ = try MeetingRecord.deleteOne(db, key: fixture.meetingId)
                #expect(try SpeakerAnalysisRecord.fetchCount(db) == 0)
            }
        }

        private func insertLegacyRows(in queue: DatabaseQueue) throws -> (meetingId: UUID, transcriptId: UUID, contactId: UUID) {
            let vaultId = UUID.v7()
            let meetingId = UUID.v7()
            let transcriptId = UUID.v7()
            let contactId = UUID.v7()
            try queue.write { db in
                try VaultRecord(
                    id: vaultId,
                    path: "/tmp/speaker-migration-vault",
                    name: "Vault",
                    createdAt: .now,
                    lastOpenedAt: .now
                ).insert(db)
                try MeetingRecord(
                    id: meetingId,
                    vaultId: vaultId,
                    projectId: nil,
                    name: "Preserved meeting",
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
                try db.execute(
                    sql: """
                    INSERT INTO transcript_segments (
                        id, meetingId, startTime, text, isConfirmed, speakerLabel
                    ) VALUES (?, ?, ?, ?, 1, 'mic')
                    """,
                    arguments: [transcriptId, meetingId, Date.now, "Preserved transcript"]
                )
                try ContactRecord(
                    id: contactId,
                    vaultId: vaultId,
                    email: "person@example.com",
                    displayName: "Person",
                    revision: 1,
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
            }
            return (meetingId, transcriptId, contactId)
        }
    }

    private struct MigrationFixture {
        let database: AppDatabaseManager
        let vaultId: UUID
        let meetingId: UUID
        let sessionId: UUID
        let spaceId: UUID
        let meetingSpeakerId: UUID
        let transcriptId: UUID
        let contactId: UUID

        // swiftlint:disable:next function_body_length
        init() throws {
            database = try AppDatabaseManager(path: ":memory:")
            meetingId = .v7()
            sessionId = .v7()
            spaceId = .v7()
            meetingSpeakerId = .v7()
            transcriptId = .v7()
            contactId = .v7()
            vaultId = .v7()
            let now = Date.now
            let analysisId = UUID.v7()
            var values = [Float](repeating: 0, count: SpeakerEmbeddingValidation.dimensionCount)
            values[0] = 1
            try database.dbQueue.write { db in
                try VaultRecord(
                    id: vaultId,
                    path: "/tmp/speaker-schema-vault",
                    name: "Vault",
                    createdAt: now,
                    lastOpenedAt: now
                ).insert(db)
                try MeetingRecord(
                    id: meetingId,
                    vaultId: vaultId,
                    projectId: nil,
                    name: "Meeting",
                    createdAt: now,
                    updatedAt: now
                ).insert(db)
                try ContactRecord(
                    id: contactId,
                    vaultId: vaultId,
                    email: "schema@example.com",
                    displayName: "Schema",
                    revision: 1,
                    createdAt: now,
                    updatedAt: now
                ).insert(db)
                try RecordingSessionRecord(
                    id: sessionId,
                    meetingId: meetingId,
                    startedAt: now,
                    endedAt: now,
                    duration: 1,
                    offsetSeconds: 0,
                    createdAt: now,
                    updatedAt: now
                ).insert(db)
                try TranscriptSegmentRecord(
                    id: transcriptId,
                    meetingId: meetingId,
                    startTime: now,
                    text: "Text",
                    translatedText: nil,
                    isConfirmed: true,
                    speakerLabel: "mic"
                ).insert(db)
                try SpeakerEmbeddingSpaceRecord(id: spaceId, space: Self.space, createdAt: now).insert(db)
                try SpeakerAnalysisRecord(
                    id: analysisId,
                    recordingSessionId: sessionId,
                    audioSource: .microphone,
                    embeddingSpaceId: spaceId,
                    state: .succeeded,
                    failureReason: nil,
                    createdAt: now,
                    updatedAt: now
                ).insert(db)
                try MeetingSpeakerRecord(
                    id: meetingSpeakerId,
                    analysisId: analysisId,
                    localSpeakerId: "speaker-0",
                    representative: SpeakerEmbeddingBlobCodec.encode(values, dimensionCount: values.count),
                    representativeQuality: 1,
                    representativeSource: .diarization,
                    profileUpdateEligible: true,
                    revision: 1,
                    createdAt: now,
                    updatedAt: now
                ).insert(db)
            }
        }

        static let space = SpeakerEmbeddingSpace(
            provider: "FluidAudio",
            modelName: "speaker-diarization",
            revision: "revision",
            assetFingerprint: "fingerprint",
            fluidAudioVersion: "0.15.5",
            dimensionCount: SpeakerEmbeddingValidation.dimensionCount,
            sampleRate: 16000,
            preprocessing: "mono-float32",
            excludesOverlap: true,
            normalization: "l2",
            similarityDefinition: "cosine-dot-product"
        )
    }
#endif
