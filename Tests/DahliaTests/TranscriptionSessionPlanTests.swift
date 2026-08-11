#if canImport(Testing)
    import Testing
    @testable import Dahlia

    struct TranscriptionSessionPlanTests {
        @Test
        func batchIsTheDefaultTranscriptionMode() {
            #expect(TranscriptionMode.defaultMode == .batch)
        }

        @Test
        func capabilitiesCoverAllModeAndSubtitleCombinations() {
            let realtimeWithoutSubtitles = TranscriptionSessionPlan(
                finalMode: .realtime,
                liveSubtitlesEnabled: false,
                retainBatchAudio: false
            )
            let realtimeWithSubtitles = TranscriptionSessionPlan(
                finalMode: .realtime,
                liveSubtitlesEnabled: true,
                retainBatchAudio: false
            )
            let batchWithoutSubtitles = TranscriptionSessionPlan(
                finalMode: .batch,
                liveSubtitlesEnabled: false,
                retainBatchAudio: true
            )
            let batchWithSubtitles = TranscriptionSessionPlan(
                finalMode: .batch,
                liveSubtitlesEnabled: true,
                retainBatchAudio: true
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
                liveSubtitlesEnabled: false,
                retainBatchAudio: true
            )

            plan.liveSubtitlesEnabled = true

            #expect(plan.finalMode == .batch)
            #expect(plan.requiresLiveRecognition)
            #expect(plan.recordsBatchAudio)
            #expect(plan.retainBatchAudio)
        }

        @Test
        func liveChatRequiresRecognitionWithoutPersistingRealtimeTranscript() {
            let plan = TranscriptionSessionPlan(
                finalMode: .batch,
                liveSubtitlesEnabled: false,
                liveChatEnabled: true,
                retainBatchAudio: true
            )

            #expect(plan.requiresLiveRecognition)
            #expect(plan.liveRecognizerCountPerSource == 1)
            #expect(plan.recordsBatchAudio)
            #expect(!plan.persistsRealtimeTranscript)
        }
    }
#endif
