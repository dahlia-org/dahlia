@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct MeetingCalendarPopupScheduleStateTests {
        @Test
        func replacementInvalidatesOldGenerationAndRetainsCurrentDelivery() {
            var state = MeetingCalendarPopupScheduleState()
            let firstGeneration = state.replace(with: ["first", "shared"])

            let claimedShared = state.claim("shared", generation: firstGeneration)
            #expect(claimedShared)

            let secondGeneration = state.replace(with: ["shared", "second"])
            let claimedFromOldGeneration = state.claim("first", generation: firstGeneration)
            let claimedSharedAgain = state.claim("shared", generation: secondGeneration)
            let claimedSecond = state.claim("second", generation: secondGeneration)
            #expect(!claimedFromOldGeneration)
            #expect(!claimedSharedAgain)
            #expect(claimedSecond)
        }

        @Test
        func cancellationInvalidatesScheduleAndCanClearDeliveryHistory() {
            var state = MeetingCalendarPopupScheduleState()
            let generation = state.replace(with: ["event"])
            let claimedEvent = state.claim("event", generation: generation)
            #expect(claimedEvent)

            state.cancel()

            let claimedAfterCancellation = state.claim("event", generation: generation)
            #expect(!claimedAfterCancellation)
            #expect(state.scheduledIdentifiers.isEmpty)
            #expect(state.deliveredIdentifiers.isEmpty)
        }
    }
#endif
