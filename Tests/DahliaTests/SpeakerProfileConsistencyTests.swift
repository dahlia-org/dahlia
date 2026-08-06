import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct SpeakerProfileConsistencyTests {
        @Test
        func assignmentInvalidationReloadsActualDatabaseProfiles() async throws {
            let fixture = try SpeakerIdentityFixture()
            let key = SpeakerProfileCacheKey(vaultId: fixture.vaultId, embeddingSpaceId: fixture.spaceId)
            _ = try await fixture.cache.profiles(for: key) { [] }
            let speaker = try fixture.addSpeaker(values: unitVector(0), source: .microphone)
            _ = try await fixture.repository.manuallyAssignSpeaker(
                meetingSpeakerId: speaker.speakerId,
                contactId: fixture.firstContactId,
                vaultId: fixture.vaultId,
                expectedRevision: 1
            )
            let query = try fixture.addSpeaker(values: unitVector(0), source: .system)
            let evaluated = try await fixture.repository.evaluateSpeakerMatch(
                meetingSpeakerId: query.speakerId,
                vaultId: fixture.vaultId,
                expectedRevision: 1
            )

            #expect(evaluated.top1ContactId == fixture.firstContactId)
            #expect(evaluated.top1Score == 1)
        }

        @Test
        func evaluationRevalidatesCachedProfilesInsideWriteTransaction() async throws {
            let fixture = try SpeakerIdentityFixture()
            let speaker = try fixture.addSpeaker(values: unitVector(0), source: .microphone)
            _ = try await fixture.repository.manuallyAssignSpeaker(
                meetingSpeakerId: speaker.speakerId,
                contactId: fixture.firstContactId,
                vaultId: fixture.vaultId,
                expectedRevision: 1
            )
            let key = SpeakerProfileCacheKey(vaultId: fixture.vaultId, embeddingSpaceId: fixture.spaceId)
            let actual = try fixture.cachedProfile(contactId: fixture.firstContactId)
            _ = try await fixture.cache.profiles(for: key) {
                [CachedSpeakerProfile(contactId: fixture.secondContactId, embedding: actual.embedding)]
            }
            let query = try fixture.addSpeaker(values: unitVector(0), source: .system)

            let evaluated = try await fixture.repository.evaluateSpeakerMatch(
                meetingSpeakerId: query.speakerId,
                vaultId: fixture.vaultId,
                expectedRevision: 1
            )

            #expect(evaluated.top1ContactId == fixture.firstContactId)
            #expect(evaluated.top1ContactId != fixture.secondContactId)
        }

        @Test
        func provisionalResolutionMovesManualAssignmentAndRecomputesProfiles() async throws {
            let fixture = try SpeakerIdentityFixture()
            try fixture.identifySecondContact(email: "identified@example.com")
            let speaker = try fixture.addSpeaker(values: unitVector(0), source: .microphone)
            _ = try await fixture.repository.manuallyAssignSpeaker(
                meetingSpeakerId: speaker.speakerId,
                contactId: fixture.firstContactId,
                vaultId: fixture.vaultId,
                expectedRevision: 1
            )

            let resolved = try fixture.repository.resolveProvisionalContact(
                id: fixture.firstContactId,
                vaultId: fixture.vaultId,
                email: "identified@example.com",
                displayName: "First",
                expectedRevision: 1,
                expectedExistingContactID: fixture.secondContactId,
                expectedExistingRevision: 1
            )
            let assignment = try await fixture.database.dbQueue.read { db in
                try SpeakerContactAssignmentRecord.fetchOne(db, key: speaker.speakerId)
            }

            #expect(resolved.id == fixture.secondContactId)
            #expect(assignment?.contactId == fixture.secondContactId)
            #expect(assignment?.origin == .manual)
            #expect(try fixture.profileIfPresent(contactId: fixture.firstContactId) == nil)
            #expect(try fixture.profile(contactId: fixture.secondContactId).contributingMeetingCount == 1)
        }

        private func unitVector(_ index: Int) -> [Float] {
            var values = [Float](repeating: 0, count: SpeakerEmbeddingValidation.dimensionCount)
            values[index] = 1
            return values
        }
    }
#endif
