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

        @Test
        func provisionalResolutionInvalidatesStaleSuggestionRevisionAndKeepsMatchApprovable() async throws {
            let fixture = try SpeakerIdentityFixture()
            try fixture.identifySecondContact(email: "identified@example.com")
            let speaker = try fixture.addSpeaker(values: unitVector(0), source: .microphone)
            try fixture.insertSuggestedMatch(speakerId: speaker.speakerId, contactId: fixture.firstContactId)
            let revisionsBeforeMerge = try await fixture.database.dbQueue.read { db in
                try (
                    #require(try SpeakerMatchObservationRecord.fetchOne(db, key: speaker.speakerId)).revision,
                    #require(try MeetingSpeakerRecord.fetchOne(db, key: speaker.speakerId)).revision
                )
            }

            _ = try fixture.repository.resolveProvisionalContact(
                id: fixture.firstContactId,
                vaultId: fixture.vaultId,
                email: "identified@example.com",
                displayName: "First",
                expectedRevision: 1,
                expectedExistingContactID: fixture.secondContactId,
                expectedExistingRevision: 1
            )
            let state = try await fixture.database.dbQueue.read { db in
                try (
                    #require(try SpeakerMatchObservationRecord.fetchOne(db, key: speaker.speakerId)),
                    #require(try MeetingSpeakerRecord.fetchOne(db, key: speaker.speakerId))
                )
            }
            #expect(state.0.state == .suggested)
            #expect(state.0.top1ContactId == fixture.secondContactId)
            #expect(state.0.top1Score == 0.9)
            #expect(state.0.revision == revisionsBeforeMerge.0 + 1)
            #expect(state.1.revision == revisionsBeforeMerge.1 + 1)

            await #expect(throws: SpeakerIdentityError.revisionConflict) {
                try await fixture.repository.approveSpeakerSuggestion(
                    meetingSpeakerId: speaker.speakerId,
                    contactId: fixture.secondContactId,
                    vaultId: fixture.vaultId,
                    expectedRevision: revisionsBeforeMerge.1
                )
            }

            let approved = try await fixture.repository.approveSpeakerSuggestion(
                meetingSpeakerId: speaker.speakerId,
                contactId: fixture.secondContactId,
                vaultId: fixture.vaultId,
                expectedRevision: state.1.revision
            )
            #expect(approved.assignedContactId == fixture.secondContactId)
            #expect(approved.assignmentOrigin == .suggestionApproved)
            #expect(approved.matchState == .referenceOnly)
        }

        @Test
        func provisionalResolutionCollapsesDuplicateCandidateToHigherScoringTop1() async throws {
            let fixture = try SpeakerIdentityFixture()
            try fixture.identifySecondContact(email: "identified@example.com")
            let speaker = try fixture.addSpeaker(values: unitVector(0), source: .microphone)
            try await fixture.database.dbQueue.write { db in
                try SpeakerMatchObservationRecord(
                    meetingSpeakerId: speaker.speakerId,
                    embeddingSpaceId: fixture.spaceId,
                    top1ContactId: fixture.firstContactId,
                    top1Score: 0.72,
                    top2ContactId: fixture.secondContactId,
                    top2Score: 0.91,
                    margin: -0.19,
                    state: .suggested,
                    unknownReason: nil,
                    revision: 1,
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
                try db.execute(
                    sql: """
                    UPDATE speaker_analyses
                    SET embeddingSpaceId = NULL, state = 'failed', failureReason = 'configuration changed'
                    WHERE id = (SELECT analysisId FROM meeting_speakers WHERE id = ?)
                    """,
                    arguments: [speaker.speakerId]
                )
            }

            _ = try fixture.repository.resolveProvisionalContact(
                id: fixture.firstContactId,
                vaultId: fixture.vaultId,
                email: "identified@example.com",
                displayName: "First",
                expectedRevision: 1,
                expectedExistingContactID: fixture.secondContactId,
                expectedExistingRevision: 1
            )
            let result = try fixture.database.dbQueue.read { db in
                let observation = try #require(
                    try SpeakerMatchObservationRecord.fetchOne(db, key: speaker.speakerId)
                )
                let integrity = try String.fetchOne(db, sql: "PRAGMA integrity_check")
                let foreignKeyViolations = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
                return (observation, integrity, foreignKeyViolations)
            }

            #expect(result.0.state == .suggested)
            #expect(result.0.top1ContactId == fixture.secondContactId)
            #expect(result.0.top1Score == 0.91)
            #expect(result.0.top2ContactId == nil)
            #expect(result.0.top2Score == nil)
            #expect(result.0.margin == nil)
            #expect(result.1 == "ok")
            #expect(result.2.isEmpty)
        }

        @Test
        func provisionalResolutionRetargetsRejectedMatchWithoutReopeningIt() async throws {
            let fixture = try SpeakerIdentityFixture()
            try fixture.identifySecondContact(email: "identified@example.com")
            let speaker = try fixture.addSpeaker(values: unitVector(0), source: .microphone)
            try await fixture.database.dbQueue.write { db in
                try SpeakerMatchObservationRecord(
                    meetingSpeakerId: speaker.speakerId,
                    embeddingSpaceId: fixture.spaceId,
                    top1ContactId: fixture.firstContactId,
                    top1Score: 0.9,
                    top2ContactId: nil,
                    top2Score: nil,
                    margin: nil,
                    state: .rejected,
                    unknownReason: nil,
                    revision: 1,
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
            }

            _ = try fixture.repository.resolveProvisionalContact(
                id: fixture.firstContactId,
                vaultId: fixture.vaultId,
                email: "identified@example.com",
                displayName: "First",
                expectedRevision: 1,
                expectedExistingContactID: fixture.secondContactId,
                expectedExistingRevision: 1
            )
            let observation = try await fixture.database.dbQueue.read { db in
                try #require(try SpeakerMatchObservationRecord.fetchOne(db, key: speaker.speakerId))
            }

            #expect(observation.state == .rejected)
            #expect(observation.top1ContactId == fixture.secondContactId)
            #expect(observation.top1Score == 0.9)
        }

        @Test
        func deletingSuggestedCandidateBecomesUndeterminableWithoutClearingRejection() async throws {
            let fixture = try SpeakerIdentityFixture()
            let suggested = try fixture.addSpeaker(values: unitVector(0), source: .microphone)
            let rejected = try fixture.addSpeaker(values: unitVector(1), source: .system)
            try fixture.insertSuggestedMatch(speakerId: suggested.speakerId, contactId: fixture.firstContactId)
            try fixture.insertSuggestedMatch(speakerId: rejected.speakerId, contactId: fixture.firstContactId)
            _ = try await fixture.repository.rejectSpeakerSuggestion(
                meetingSpeakerId: rejected.speakerId,
                vaultId: fixture.vaultId,
                expectedRevision: 1
            )

            try fixture.repository.deleteProvisionalContact(
                id: fixture.firstContactId,
                vaultId: fixture.vaultId,
                expectedRevision: 1
            )
            let result = try fixture.database.dbQueue.read { db in
                let suggestedObservation = try #require(
                    try SpeakerMatchObservationRecord.fetchOne(db, key: suggested.speakerId)
                )
                let rejectedObservation = try #require(
                    try SpeakerMatchObservationRecord.fetchOne(db, key: rejected.speakerId)
                )
                let integrity = try String.fetchOne(db, sql: "PRAGMA integrity_check")
                let foreignKeyViolations = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
                return (suggestedObservation, rejectedObservation, integrity, foreignKeyViolations)
            }

            #expect(result.0.state == .undeterminable)
            #expect(result.0.unknownReason == .insufficientEvidence)
            #expect(result.0.top1ContactId == nil)
            #expect(result.0.top1Score == nil)
            #expect(result.0.margin == nil)
            #expect(result.1.state == .rejected)
            #expect(result.1.unknownReason == nil)
            #expect(result.1.top1ContactId == nil)
            #expect(result.1.top1Score == nil)
            #expect(result.2 == "ok")
            #expect(result.3.isEmpty)
        }

        @Test
        func rejectionRemainsStickyWhenReevaluationFindsADifferentContact() async throws {
            let fixture = try SpeakerIdentityFixture()
            let suggested = try fixture.addSpeaker(values: unitVector(1), source: .system)
            try fixture.insertSuggestedMatch(speakerId: suggested.speakerId, contactId: fixture.firstContactId)
            _ = try await fixture.repository.rejectSpeakerSuggestion(
                meetingSpeakerId: suggested.speakerId,
                vaultId: fixture.vaultId,
                expectedRevision: 1
            )
            try fixture.repository.deleteProvisionalContact(
                id: fixture.firstContactId,
                vaultId: fixture.vaultId,
                expectedRevision: 1
            )
            let trainingSpeaker = try fixture.addSpeaker(values: unitVector(1), source: .microphone)
            _ = try await fixture.repository.manuallyAssignSpeaker(
                meetingSpeakerId: trainingSpeaker.speakerId,
                contactId: fixture.secondContactId,
                vaultId: fixture.vaultId,
                expectedRevision: 1
            )

            let reevaluated = try await fixture.repository.evaluateSpeakerMatch(
                meetingSpeakerId: suggested.speakerId,
                vaultId: fixture.vaultId,
                expectedRevision: 2
            )

            #expect(reevaluated.top1ContactId == fixture.secondContactId)
            #expect(reevaluated.matchState == .rejected)
        }

        private func unitVector(_ index: Int) -> [Float] {
            var values = [Float](repeating: 0, count: SpeakerEmbeddingValidation.dimensionCount)
            values[index] = 1
            return values
        }
    }
#endif
