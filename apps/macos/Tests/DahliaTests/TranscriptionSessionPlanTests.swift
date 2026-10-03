#if canImport(Testing)
    import Testing
    @testable import Dahlia

    struct TranscriptionSessionPlanTests {
        @Test(arguments: [false, true], [false, true])
        func liveDraftIsIndependentOfSubtitlesAndSharesRecognition(draft: Bool, subtitles: Bool) {
            let plan = TranscriptionSessionPlan(
                finalMode: .batch,
                liveSubtitlesEnabled: subtitles,
                liveTranscriptDraftEnabled: draft
            )
            #expect(plan.recordsBatchAudio)
            #expect(plan.persistsRealtimeTranscript == draft)
            #expect(plan.liveRecognizerCountPerSource == (draft || subtitles ? 1 : 0))
        }

        @Test
        func batchIsTheDefaultTranscriptionMode() {
            #expect(TranscriptionMode.defaultMode == .batch)
        }

        @Test
        func capabilitiesCoverAllModeAndSubtitleCombinations() {
            let realtimeWithoutSubtitles = TranscriptionSessionPlan(
                finalMode: .realtime,
                liveSubtitlesEnabled: false
            )
            let realtimeWithSubtitles = TranscriptionSessionPlan(
                finalMode: .realtime,
                liveSubtitlesEnabled: true
            )
            let batchWithoutSubtitles = TranscriptionSessionPlan(
                finalMode: .batch,
                liveSubtitlesEnabled: false
            )
            let batchWithSubtitles = TranscriptionSessionPlan(
                finalMode: .batch,
                liveSubtitlesEnabled: true
            )

            #expect(realtimeWithoutSubtitles.requiresLiveRecognition)
            #expect(realtimeWithoutSubtitles.liveRecognizerCountPerSource == 1)
            #expect(realtimeWithoutSubtitles.batchRecorderCountPerSource == 0)
            #expect(!realtimeWithoutSubtitles.recordsBatchAudio)
            #expect(realtimeWithoutSubtitles.persistsRealtimeTranscript)

            #expect(realtimeWithSubtitles.requiresLiveRecognition)
            #expect(realtimeWithSubtitles.liveRecognizerCountPerSource == 1)
            #expect(realtimeWithSubtitles.batchRecorderCountPerSource == 0)
            #expect(!realtimeWithSubtitles.recordsBatchAudio)
            #expect(realtimeWithSubtitles.persistsRealtimeTranscript)

            #expect(!batchWithoutSubtitles.requiresLiveRecognition)
            #expect(batchWithoutSubtitles.liveRecognizerCountPerSource == 0)
            #expect(batchWithoutSubtitles.batchRecorderCountPerSource == 1)
            #expect(batchWithoutSubtitles.recordsBatchAudio)
            #expect(!batchWithoutSubtitles.persistsRealtimeTranscript)

            #expect(batchWithSubtitles.requiresLiveRecognition)
            #expect(batchWithSubtitles.liveRecognizerCountPerSource == 1)
            #expect(batchWithSubtitles.batchRecorderCountPerSource == 1)
            #expect(batchWithSubtitles.recordsBatchAudio)
            #expect(!batchWithSubtitles.persistsRealtimeTranscript)
        }

        @Test
        func liveSubtitleCapabilityCanChangeWithoutChangingFinalMode() {
            var plan = TranscriptionSessionPlan(
                finalMode: .batch,
                liveSubtitlesEnabled: false
            )

            plan.liveSubtitlesEnabled = true

            #expect(plan.finalMode == .batch)
            #expect(plan.requiresLiveRecognition)
            #expect(plan.recordsBatchAudio)
        }

    }
#endif
