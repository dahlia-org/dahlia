import Foundation
import GRDB

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
        func realtimeRetainsFinalizedHistoryWhileLiveSubtitlesAreDisabled() {
            let sessionID = UUID.v7()
            let liveStore = LiveCaptionStore()
            liveStore.start(sessionId: sessionID)
            let plan = TranscriptionSessionPlan(
                finalMode: .realtime,
                liveSubtitlesEnabled: false,
                retainBatchAudio: false
            )

            for index in 0 ... TranscriptStore.maximumConfirmedSegmentCount {
                TranscriptionEventRouter.routeLiveCaption(
                    .finalized(TranscriptSegment(
                        sessionId: sessionID,
                        startTime: Date(timeIntervalSince1970: 1_776_384_000 + Double(index)),
                        text: "Segment \(index)",
                        isConfirmed: true,
                        speakerLabel: "system"
                    )),
                    plan: plan,
                    liveCaptionStore: liveStore
                )
            }

            #expect(liveStore.segments.count == TranscriptStore.maximumConfirmedSegmentCount + 1)
            #expect(liveStore.segments.first?.text == "Segment 0")
            #expect(liveStore.segments.last?.text == "Segment \(TranscriptStore.maximumConfirmedSegmentCount)")
        }

        @Test
        func realtimePersistsTranslationWhileLiveSubtitlesAreDisabled() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let vault = VaultRecord(
                id: .v7(),
                path: "/tmp/translated-meeting-vault",
                name: "Test Vault",
                createdAt: Date(timeIntervalSince1970: 1_776_380_000),
                lastOpenedAt: Date(timeIntervalSince1970: 1_776_380_000)
            )
            try await database.dbQueue.write { db in
                try vault.insert(db)
            }
            let transcriptStore = TranscriptStore()
            transcriptStore.recordingStartTime = Date(timeIntervalSince1970: 1_776_384_000)
            let persistenceService = try await MeetingPersistenceService.createNew(
                store: transcriptStore,
                dbQueue: database.dbQueue,
                vaultId: vault.id,
                projectId: nil,
                initialName: "Translated meeting"
            )
            let segment = makeSegment(sessionID: persistenceService.recordingSessionId)
            let plan = TranscriptionSessionPlan(
                finalMode: .realtime,
                liveSubtitlesEnabled: false,
                retainBatchAudio: false
            )
            let pipeline = TranscriptionEventPipeline(
                uiSink: { events in
                    for event in events {
                        TranscriptionEventRouter.routeTranscriptProjection(
                            event,
                            plan: plan,
                            transcriptStore: transcriptStore
                        )
                    }
                },
                persistenceSink: { events in
                    try await persistenceService.persist(events)
                },
                persistenceFlushSink: {
                    try await persistenceService.flushPendingTranscriptEvents()
                }
            )

            await pipeline.start()
            await pipeline.enqueue(.finalized(segment))
            await pipeline.enqueue(.translation(
                sessionId: persistenceService.recordingSessionId,
                segmentID: segment.id,
                translatedText: "Translated"
            ))
            try await pipeline.finish()

            let persistedTranslation = try await database.dbQueue.read { db in
                try TranscriptSegmentRecord.fetchOne(db, key: segment.id)?.translatedText
            }
            #expect(persistedTranslation == "Translated")
            #expect(transcriptStore.segments.first?.translatedText == "Translated")

            _ = await persistenceService.stop()
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
