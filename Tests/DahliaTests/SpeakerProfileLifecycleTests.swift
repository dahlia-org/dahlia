import DahliaRuntimeSupport
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct SpeakerProfileLifecycleTests {
        @Test
        func profileUsesEqualWeightPerMeetingAndOnlyLearnableConfirmations() async throws {
            let fixture = try SpeakerIdentityFixture()
            let first = try fixture.addSpeaker(values: unitVector(0), source: .microphone)
            let second = try fixture.addSpeaker(meetingId: first.meetingId, values: unitVector(1), source: .system)
            let third = try fixture.addSpeaker(values: unitVector(0), source: .microphone)

            _ = try await fixture.repository.manuallyAssignSpeaker(
                meetingSpeakerId: first.speakerId,
                contactId: fixture.firstContactId,
                vaultId: fixture.vaultId,
                expectedRevision: 1
            )
            _ = try await fixture.repository.manuallyAssignSpeaker(
                meetingSpeakerId: second.speakerId,
                contactId: fixture.firstContactId,
                vaultId: fixture.vaultId,
                expectedRevision: 1
            )
            _ = try await fixture.repository.manuallyAssignSpeaker(
                meetingSpeakerId: third.speakerId,
                contactId: fixture.firstContactId,
                vaultId: fixture.vaultId,
                expectedRevision: 1
            )

            let profile = try fixture.profile(contactId: fixture.firstContactId)
            let values = try SpeakerEmbeddingBlobCodec.decode(
                profile.representative,
                dimensionCount: SpeakerEmbeddingValidation.dimensionCount
            )
            #expect(profile.contributingMeetingCount == 2)
            #expect(abs(values[0] - 0.923_879_5) < 0.000_01)
            #expect(abs(values[1] - 0.382_683_4) < 0.000_01)

            let referenceOnly = try fixture.addSpeaker(values: unitVector(0), source: .microphone)
            _ = try await fixture.repository.evaluateSpeakerMatch(
                meetingSpeakerId: referenceOnly.speakerId,
                vaultId: fixture.vaultId,
                expectedRevision: 1
            )
            #expect(try fixture.profile(contactId: fixture.firstContactId).contributingMeetingCount == 2)

            try fixture.insertSuggestedMatch(speakerId: referenceOnly.speakerId, contactId: fixture.firstContactId)
            let approved = try await fixture.repository.approveSpeakerSuggestion(
                meetingSpeakerId: referenceOnly.speakerId,
                contactId: fixture.firstContactId,
                vaultId: fixture.vaultId,
                expectedRevision: 2
            )
            #expect(approved.assignmentOrigin == .suggestionApproved)
            #expect(approved.matchState == .referenceOnly)
            #expect(try fixture.profile(contactId: fixture.firstContactId).contributingMeetingCount == 3)
            let repeatedApproval = try await fixture.repository.approveSpeakerSuggestion(
                meetingSpeakerId: referenceOnly.speakerId,
                contactId: fixture.firstContactId,
                vaultId: fixture.vaultId,
                expectedRevision: 2
            )
            #expect(repeatedApproval == approved)
        }

        @Test
        func assignmentChangeClearAndMeetingDeletionRecomputeBothProfiles() async throws {
            let fixture = try SpeakerIdentityFixture()
            let first = try fixture.addSpeaker(values: unitVector(0), source: .microphone)
            let second = try fixture.addSpeaker(values: unitVector(1), source: .system)
            _ = try await fixture.repository.manuallyAssignSpeaker(
                meetingSpeakerId: first.speakerId,
                contactId: fixture.firstContactId,
                vaultId: fixture.vaultId,
                expectedRevision: 1
            )
            _ = try await fixture.repository.manuallyAssignSpeaker(
                meetingSpeakerId: second.speakerId,
                contactId: fixture.firstContactId,
                vaultId: fixture.vaultId,
                expectedRevision: 1
            )

            let changed = try await fixture.repository.changeSpeakerAssignment(
                meetingSpeakerId: second.speakerId,
                contactId: fixture.secondContactId,
                vaultId: fixture.vaultId,
                expectedRevision: 2
            )
            #expect(changed.assignedContactId == fixture.secondContactId)
            #expect(try fixture.profile(contactId: fixture.firstContactId).contributingMeetingCount == 1)
            #expect(try fixture.profile(contactId: fixture.secondContactId).contributingMeetingCount == 1)

            let cleared = try await fixture.repository.clearSpeakerAssignment(
                meetingSpeakerId: second.speakerId,
                vaultId: fixture.vaultId,
                expectedRevision: 3
            )
            #expect(cleared.assignedContactId == nil)
            #expect(try fixture.profileIfPresent(contactId: fixture.secondContactId) == nil)

            let third = try fixture.addSpeaker(values: unitVector(1), source: .system)
            _ = try await fixture.repository.manuallyAssignSpeaker(
                meetingSpeakerId: third.speakerId,
                contactId: fixture.firstContactId,
                vaultId: fixture.vaultId,
                expectedRevision: 1
            )
            #expect(try fixture.profile(contactId: fixture.firstContactId).contributingMeetingCount == 2)
            try fixture.repository.deleteMeeting(id: third.meetingId)
            #expect(try fixture.profile(contactId: fixture.firstContactId).contributingMeetingCount == 1)

            let projectMeeting = try fixture.addSpeaker(values: unitVector(1), source: .system)
            _ = try await fixture.repository.manuallyAssignSpeaker(
                meetingSpeakerId: projectMeeting.speakerId,
                contactId: fixture.firstContactId,
                vaultId: fixture.vaultId,
                expectedRevision: 1
            )
            try fixture.attachToProject(meetingId: projectMeeting.meetingId, name: "Speaker Project")
            #expect(try fixture.profile(contactId: fixture.firstContactId).contributingMeetingCount == 2)
            _ = try fixture.repository.deleteProjectHierarchy(
                name: "Speaker Project",
                vaultId: fixture.vaultId,
                meetingDisposition: .deleteMeetings
            )
            #expect(try fixture.profile(contactId: fixture.firstContactId).contributingMeetingCount == 1)
        }

        @Test
        func contactAndVaultDeletionCascadeBiometricData() async throws {
            let fixture = try SpeakerIdentityFixture()
            let speaker = try fixture.addSpeaker(values: unitVector(0), source: .microphone)
            _ = try await fixture.repository.manuallyAssignSpeaker(
                meetingSpeakerId: speaker.speakerId,
                contactId: fixture.firstContactId,
                vaultId: fixture.vaultId,
                expectedRevision: 1
            )
            let reference = try fixture.addSpeaker(values: unitVector(0), source: .system)
            _ = try await fixture.repository.evaluateSpeakerMatch(
                meetingSpeakerId: reference.speakerId,
                vaultId: fixture.vaultId,
                expectedRevision: 1
            )
            let impact = try fixture.repository.provisionalContactDeletionImpact(
                id: fixture.firstContactId,
                vaultId: fixture.vaultId
            )
            #expect(impact.speakerProfiles == 1)
            #expect(impact.speakerAssignments == 1)
            try fixture.repository.deleteProvisionalContact(
                id: fixture.firstContactId,
                vaultId: fixture.vaultId,
                expectedRevision: 1
            )
            let afterContactDelete = try await fixture.database.dbQueue.read { db in
                try (
                    SpeakerProfileRecord.filter(Column("contactId") == fixture.firstContactId).fetchCount(db),
                    SpeakerContactAssignmentRecord.filter(Column("contactId") == fixture.firstContactId).fetchCount(db),
                    SpeakerMatchObservationRecord.fetchOne(db, key: reference.speakerId)
                )
            }
            #expect(afterContactDelete.0 == 0)
            #expect(afterContactDelete.1 == 0)
            #expect(afterContactDelete.2?.state == .referenceOnly)
            #expect(afterContactDelete.2?.top1ContactId == nil)

            let remaining = try fixture.addSpeaker(values: unitVector(1), source: .system)
            _ = try await fixture.repository.manuallyAssignSpeaker(
                meetingSpeakerId: remaining.speakerId,
                contactId: fixture.secondContactId,
                vaultId: fixture.vaultId,
                expectedRevision: 1
            )
            try fixture.repository.deleteVault(id: fixture.vaultId)
            let counts = try await fixture.database.dbQueue.read { db in
                try (
                    SpeakerAnalysisRecord.fetchCount(db),
                    MeetingSpeakerRecord.fetchCount(db),
                    SpeakerProfileRecord.fetchCount(db)
                )
            }
            #expect(counts.0 == 0)
            #expect(counts.1 == 0)
            #expect(counts.2 == 0)
        }

        @Test
        func speakerDatabaseOnlyRepresentativeIsStructurallyBarredFromLearning() throws {
            let fixture = try SpeakerIdentityFixture()
            #expect(throws: (any Error).self) {
                _ = try fixture.addSpeaker(
                    values: unitVector(0),
                    source: .microphone,
                    representativeSource: .speakerDatabase,
                    profileUpdateEligible: true
                )
            }
        }

        @Test
        // swiftlint:disable:next function_body_length
        func repositoryOperationsAreVaultScopedRevisionCheckedAndIdempotent() async throws {
            let fixture = try SpeakerIdentityFixture()
            let speaker = try fixture.addSpeaker(values: unitVector(0), source: .microphone)
            let assigned = try await fixture.repository.manuallyAssignSpeaker(
                meetingSpeakerId: speaker.speakerId,
                contactId: fixture.firstContactId,
                vaultId: fixture.vaultId,
                expectedRevision: 1
            )
            let repeated = try await fixture.repository.manuallyAssignSpeaker(
                meetingSpeakerId: speaker.speakerId,
                contactId: fixture.firstContactId,
                vaultId: fixture.vaultId,
                expectedRevision: 1
            )
            #expect(assigned.revision == 2)
            #expect(repeated == assigned)

            await #expect(throws: SpeakerIdentityError.revisionConflict) {
                try await fixture.repository.changeSpeakerAssignment(
                    meetingSpeakerId: speaker.speakerId,
                    contactId: fixture.secondContactId,
                    vaultId: fixture.vaultId,
                    expectedRevision: 1
                )
            }
            await #expect(throws: SpeakerIdentityError.candidateNotFound) {
                try await fixture.repository.clearSpeakerAssignment(
                    meetingSpeakerId: speaker.speakerId,
                    vaultId: .v7(),
                    expectedRevision: 2
                )
            }

            let cleared = try await fixture.repository.clearSpeakerAssignment(
                meetingSpeakerId: speaker.speakerId,
                vaultId: fixture.vaultId,
                expectedRevision: 2
            )
            let repeatedClear = try await fixture.repository.clearSpeakerAssignment(
                meetingSpeakerId: speaker.speakerId,
                vaultId: fixture.vaultId,
                expectedRevision: 2
            )
            #expect(cleared.revision == 3)
            #expect(repeatedClear == cleared)

            let suggested = try fixture.addSpeaker(values: unitVector(1), source: .system)
            try fixture.insertSuggestedMatch(speakerId: suggested.speakerId, contactId: fixture.secondContactId)
            let rejected = try await fixture.repository.rejectSpeakerSuggestion(
                meetingSpeakerId: suggested.speakerId,
                vaultId: fixture.vaultId,
                expectedRevision: 1
            )
            let repeatedRejection = try await fixture.repository.rejectSpeakerSuggestion(
                meetingSpeakerId: suggested.speakerId,
                vaultId: fixture.vaultId,
                expectedRevision: 1
            )
            #expect(rejected.matchState == .rejected)
            #expect(repeatedRejection == rejected)

            let reevaluated = try await fixture.repository.evaluateSpeakerMatch(
                meetingSpeakerId: suggested.speakerId,
                vaultId: fixture.vaultId,
                expectedRevision: 2
            )
            #expect(reevaluated.matchState == .rejected)
        }

        private func unitVector(_ index: Int) -> [Float] {
            var values = [Float](repeating: 0, count: SpeakerEmbeddingValidation.dimensionCount)
            values[index] = 1
            return values
        }
    }

    final class SpeakerIdentityFixture: Sendable {
        let database: AppDatabaseManager
        let cache: SpeakerProfileCache
        let repository: MeetingRepository
        let vaultId: UUID
        let firstContactId: UUID
        let secondContactId: UUID
        let spaceId: UUID

        init() throws {
            database = try AppDatabaseManager(path: ":memory:")
            cache = SpeakerProfileCache()
            repository = MeetingRepository(dbQueue: database.dbQueue, speakerProfileCache: cache)
            vaultId = .v7()
            firstContactId = .v7()
            secondContactId = .v7()
            spaceId = .v7()
            let now = Date.now
            try database.dbQueue.write { db in
                try VaultRecord(
                    id: vaultId,
                    path: "/tmp/speaker-profile-\(vaultId)",
                    name: "Vault",
                    createdAt: now,
                    lastOpenedAt: now
                ).insert(db)
                try ContactRecord(
                    id: firstContactId,
                    vaultId: vaultId,
                    email: nil,
                    displayName: "First",
                    revision: 1,
                    createdAt: now,
                    updatedAt: now
                ).insert(db)
                try ContactRecord(
                    id: secondContactId,
                    vaultId: vaultId,
                    email: nil,
                    displayName: "Second",
                    revision: 1,
                    createdAt: now,
                    updatedAt: now
                ).insert(db)
                try SpeakerEmbeddingSpaceRecord(id: spaceId, space: Self.space, createdAt: now).insert(db)
            }
        }

        func addSpeaker(
            meetingId requestedMeetingId: UUID? = nil,
            values: [Float],
            source: RecordingAudioSource,
            representativeSource: SpeakerRepresentativeSource = .diarization,
            profileUpdateEligible: Bool = true
        ) throws -> (meetingId: UUID, speakerId: UUID) {
            let meetingId = requestedMeetingId ?? UUID.v7()
            let sessionId = UUID.v7()
            let analysisId = UUID.v7()
            let speakerId = UUID.v7()
            let now = Date.now
            try database.dbQueue.write { db in
                if requestedMeetingId == nil {
                    try MeetingRecord(
                        id: meetingId,
                        vaultId: vaultId,
                        projectId: nil,
                        name: "Meeting",
                        createdAt: now,
                        updatedAt: now
                    ).insert(db)
                }
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
                try SpeakerAnalysisRecord(
                    id: analysisId,
                    recordingSessionId: sessionId,
                    audioSource: source,
                    embeddingSpaceId: spaceId,
                    state: .succeeded,
                    failureReason: nil,
                    createdAt: now,
                    updatedAt: now
                ).insert(db)
                try MeetingSpeakerRecord(
                    id: speakerId,
                    analysisId: analysisId,
                    localSpeakerId: "speaker-\(speakerId)",
                    representative: SpeakerEmbeddingBlobCodec.encode(values, dimensionCount: values.count),
                    representativeQuality: 1,
                    representativeSource: representativeSource,
                    profileUpdateEligible: profileUpdateEligible,
                    revision: 1,
                    createdAt: now,
                    updatedAt: now
                ).insert(db)
            }
            return (meetingId, speakerId)
        }

        func profile(contactId: UUID) throws -> SpeakerProfileRecord {
            guard let profile = try profileIfPresent(contactId: contactId) else {
                throw SpeakerIdentityError.invalidEmbedding
            }
            return profile
        }

        func profileIfPresent(contactId: UUID) throws -> SpeakerProfileRecord? {
            try database.dbQueue.read { db in
                try SpeakerProfileRecord
                    .filter(Column("contactId") == contactId && Column("embeddingSpaceId") == spaceId)
                    .fetchOne(db)
            }
        }

        func insertSuggestedMatch(speakerId: UUID, contactId: UUID) throws {
            try database.dbQueue.write { db in
                let now = Date.now
                try SpeakerMatchObservationRecord(
                    meetingSpeakerId: speakerId,
                    embeddingSpaceId: spaceId,
                    top1ContactId: contactId,
                    top1Score: 0.9,
                    top2ContactId: nil,
                    top2Score: nil,
                    margin: nil,
                    state: .suggested,
                    unknownReason: nil,
                    revision: 2,
                    createdAt: now,
                    updatedAt: now
                ).save(db)
            }
        }

        func identifySecondContact(email: String) throws {
            try database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE contacts SET email = ? WHERE id = ?",
                    arguments: [email, secondContactId]
                )
            }
        }

        func attachToProject(meetingId: UUID, name: String) throws {
            try database.dbQueue.write { db in
                let projectId = UUID.v7()
                try ProjectRecord(
                    id: projectId,
                    vaultId: vaultId,
                    parentProjectId: nil,
                    name: name,
                    createdAt: .now,
                    projectType: .undefined
                ).insert(db)
                try MeetingRecord
                    .filter(Column("id") == meetingId)
                    .updateAll(db, Column("projectId").set(to: projectId))
            }
        }

        func cachedProfile(contactId: UUID) throws -> CachedSpeakerProfile {
            let profile = try profile(contactId: contactId)
            return try CachedSpeakerProfile(
                contactId: contactId,
                embedding: SpeakerEmbedding(
                    space: Self.space,
                    values: SpeakerEmbeddingBlobCodec.decode(
                        profile.representative,
                        dimensionCount: SpeakerEmbeddingValidation.dimensionCount
                    )
                )
            )
        }

        private static let space = SpeakerEmbeddingSpace(
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
