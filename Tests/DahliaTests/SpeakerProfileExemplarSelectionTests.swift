@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct SpeakerProfileExemplarSelectionTests {
        @Test
        func greedilyPrefersMeetingAndAudioSourceDiversityWithFiveItemCap() async throws {
            let fixture = try SpeakerIdentityFixture()
            let first = try fixture.addSpeaker(values: unitVector(0), source: .microphone, quality: 0.99)
            let naiveSecond = try fixture.addSpeaker(
                meetingId: first.meetingId,
                values: unitVector(1),
                source: .microphone,
                quality: 0.98
            )
            let newMeetingSameSource = try fixture.addSpeaker(values: unitVector(2), source: .microphone, quality: 0.7)
            let sameMeetingNewSource = try fixture.addSpeaker(
                meetingId: first.meetingId,
                values: unitVector(3),
                source: .system,
                quality: 0.6
            )
            let newMeetingNewSource = try fixture.addSpeaker(values: unitVector(4), source: .system, quality: 0.5)
            let fourthMeeting = try fixture.addSpeaker(values: unitVector(5), source: .microphone, quality: 0.4)
            let speakers = [first, naiveSecond, newMeetingSameSource, sameMeetingNewSource, newMeetingNewSource, fourthMeeting]
            for speaker in speakers {
                _ = try await fixture.repository.manuallyAssignSpeaker(
                    meetingSpeakerId: speaker.speakerId,
                    contactId: fixture.firstContactId,
                    vaultId: fixture.vaultId,
                    expectedRevision: 1
                )
            }

            let selected = try fixture.profileExemplarSpeakerIds(contactId: fixture.firstContactId)

            #expect(selected == [
                first.speakerId,
                newMeetingNewSource.speakerId,
                newMeetingSameSource.speakerId,
                fourthMeeting.speakerId,
                naiveSecond.speakerId,
            ])
            #expect(!selected.contains(sameMeetingNewSource.speakerId))
        }

        private func unitVector(_ index: Int) -> [Float] {
            var values = [Float](repeating: 0, count: SpeakerEmbeddingValidation.dimensionCount)
            values[index] = 1
            return values
        }
    }
#endif
