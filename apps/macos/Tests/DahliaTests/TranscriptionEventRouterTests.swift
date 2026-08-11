import Foundation

#if canImport(Testing)
    import Testing
    @testable import Dahlia

    @MainActor
    struct TranscriptionEventRouterTests {
        @Test
        func realtimeAndLiveShareOneEventWithoutDuplicatingEitherStore() {
            let sessionID = UUID.v7()
            let segment = makeSegment(sessionID: sessionID)
            let transcriptStore = TranscriptStore()
            let liveStore = LiveCaptionStore()
            liveStore.start(sessionId: sessionID)
            let plan = TranscriptionSessionPlan(
                finalMode: .realtime,
                liveSubtitlesEnabled: true,
                retainBatchAudio: false
            )

            TranscriptionEventRouter.routeTranscriptProjection(
                .finalized(segment),
                plan: plan,
                transcriptStore: transcriptStore
            )
            TranscriptionEventRouter.routeLiveCaption(
                .finalized(segment),
                plan: plan,
                liveCaptionStore: liveStore
            )

            #expect(transcriptStore.segments == [segment])
            #expect(liveStore.segments == [segment])
        }

        @Test
        func batchLiveCaptionRoutesIndependentlyFromReloadableTranscriptProjection() {
            let sessionID = UUID.v7()
            let segment = makeSegment(sessionID: sessionID)
            let transcriptStore = TranscriptStore()
            let liveStore = LiveCaptionStore()
            liveStore.start(sessionId: sessionID)
            let plan = TranscriptionSessionPlan(
                finalMode: .batch,
                liveSubtitlesEnabled: true,
                retainBatchAudio: false
            )

            TranscriptionEventRouter.routeTranscriptProjection(
                .finalized(segment),
                plan: plan,
                transcriptStore: transcriptStore
            )
            TranscriptionEventRouter.routeLiveCaption(
                .finalized(segment),
                plan: plan,
                liveCaptionStore: liveStore
            )

            #expect(transcriptStore.segments.isEmpty)
            #expect(liveStore.segments == [segment])
        }

        @Test
        func batchWithoutLiveIgnoresStreamingEvents() {
            let sessionID = UUID.v7()
            let segment = makeSegment(sessionID: sessionID)
            let transcriptStore = TranscriptStore()
            let liveStore = LiveCaptionStore()
            liveStore.start(sessionId: sessionID)
            let plan = TranscriptionSessionPlan(
                finalMode: .batch,
                liveSubtitlesEnabled: false,
                retainBatchAudio: false
            )

            TranscriptionEventRouter.routeTranscriptProjection(
                .finalized(segment),
                plan: plan,
                transcriptStore: transcriptStore
            )
            TranscriptionEventRouter.routeLiveCaption(
                .finalized(segment),
                plan: plan,
                liveCaptionStore: liveStore
            )

            #expect(transcriptStore.segments.isEmpty)
            #expect(liveStore.segments.isEmpty)
        }

        @Test
        func finalizationRemovesMatchingPreviewSynchronously() {
            let sessionID = UUID.v7()
            let segmentID = UUID.v7()
            let transcriptStore = TranscriptStore()
            let plan = TranscriptionSessionPlan(
                finalMode: .realtime,
                liveSubtitlesEnabled: false,
                retainBatchAudio: false
            )
            let preview = TranscriptSegment(
                id: segmentID,
                sessionId: sessionID,
                startTime: Date(timeIntervalSince1970: 1_776_384_000),
                text: "Preview",
                isConfirmed: false,
                speakerLabel: "mic"
            )
            var final = preview
            final.text = "Final"
            final.isConfirmed = true

            TranscriptionEventRouter.routeTranscriptProjection(
                .preview(preview),
                plan: plan,
                transcriptStore: transcriptStore
            )
            TranscriptionEventRouter.routeTranscriptProjection(
                .finalized(final),
                plan: plan,
                transcriptStore: transcriptStore
            )

            #expect(transcriptStore.segments == [final])
        }

        private func makeSegment(sessionID: UUID) -> TranscriptSegment {
            TranscriptSegment(
                sessionId: sessionID,
                startTime: Date(timeIntervalSince1970: 1_776_384_000),
                text: "Shared recognition",
                isConfirmed: true,
                speakerLabel: "system"
            )
        }
    }
#endif
