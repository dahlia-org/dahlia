import Foundation

#if canImport(Testing)
    import Testing
    @testable import Dahlia

    @MainActor
    struct LiveCaptionStoreTests {
        @Test
        func previewUpsertIsIndependentForEachSource() {
            let sessionID = UUID.v7()
            let store = LiveCaptionStore()
            store.start(sessionId: sessionID)

            store.apply(event: .preview(makeSegment(sessionID: sessionID, text: "Mic first", source: "mic")))
            store.apply(event: .preview(makeSegment(sessionID: sessionID, text: "System", source: "system")))
            store.apply(event: .preview(makeSegment(sessionID: sessionID, text: "Mic latest", source: "mic")))

            #expect(store.segments.count == 2)
            #expect(store.segments.first(where: { $0.speakerLabel == "mic" })?.text == "Mic latest")
            #expect(store.segments.first(where: { $0.speakerLabel == "system" })?.text == "System")
            #expect(store.segments.allSatisfy { !$0.isConfirmed })
        }

        @Test
        func finalizedEventClearsOnlyItsSourcePreviewAndAcceptsTranslation() throws {
            let sessionID = UUID.v7()
            let finalizedID = UUID.v7()
            let store = LiveCaptionStore()
            store.start(sessionId: sessionID)
            store.apply(event: .preview(makeSegment(sessionID: sessionID, text: "Mic preview", source: "mic")))
            store.apply(event: .preview(makeSegment(sessionID: sessionID, text: "System preview", source: "system")))

            store.apply(event: .finalized(makeSegment(
                id: finalizedID,
                sessionID: sessionID,
                text: "Mic final",
                source: "mic"
            )))
            store.apply(event: .translation(
                sessionId: sessionID,
                segmentID: finalizedID,
                translatedText: "マイク確定"
            ))

            let finalized = try #require(store.segments.first(where: { $0.id == finalizedID }))
            #expect(finalized.isConfirmed)
            #expect(finalized.translatedText == "マイク確定")
            #expect(!store.segments.contains(where: { $0.text == "Mic preview" }))
            #expect(store.segments.contains(where: { $0.text == "System preview" && !$0.isConfirmed }))

            store.apply(event: .clearPreview(sessionId: sessionID, sourceLabel: "system"))
            #expect(store.segments == [finalized])
        }

        @Test
        func eventsFromInactiveSessionAreIgnored() {
            let activeSessionID = UUID.v7()
            let inactiveSessionID = UUID.v7()
            let segment = makeSegment(sessionID: activeSessionID, text: "Active", source: "mic")
            let store = LiveCaptionStore()
            store.start(sessionId: activeSessionID)
            store.apply(event: .finalized(segment))

            store.apply(event: .preview(makeSegment(
                sessionID: inactiveSessionID,
                text: "Stale preview",
                source: "system"
            )))
            store.apply(event: .clearPreview(sessionId: inactiveSessionID, sourceLabel: "mic"))
            store.apply(event: .translation(
                sessionId: inactiveSessionID,
                segmentID: segment.id,
                translatedText: "古い翻訳"
            ))
            store.apply(event: .failure(
                sessionId: inactiveSessionID,
                pipelineID: .v7(),
                sourceLabel: "system",
                message: "Stale failure"
            ))

            #expect(store.segments == [segmentWithConfirmation(segment)])
            #expect(store.failureMessage == nil)
        }

        @Test
        func seedFiltersSegmentsAndCannotReactivateAnOldSession() {
            let activeSessionID = UUID.v7()
            let oldSessionID = UUID.v7()
            let activeSegment = makeSegment(
                sessionID: activeSessionID,
                text: "Active",
                source: "mic",
                isConfirmed: true
            )
            let oldSegment = makeSegment(
                sessionID: oldSessionID,
                text: "Old",
                source: "system",
                isConfirmed: true
            )
            let store = LiveCaptionStore()
            store.start(sessionId: activeSessionID)

            store.seed([oldSegment, activeSegment], sessionId: activeSessionID)
            #expect(store.segments == [activeSegment])

            store.seed([oldSegment], sessionId: oldSessionID)
            #expect(store.activeSessionId == activeSessionID)
            #expect(store.segments == [activeSegment])
        }

        @Test
        func startingNewSessionAndClearingResetTransientState() {
            let firstSessionID = UUID.v7()
            let secondSessionID = UUID.v7()
            let store = LiveCaptionStore()
            store.start(sessionId: firstSessionID)
            store.apply(event: .preview(makeSegment(sessionID: firstSessionID, text: "Preview", source: "mic")))
            store.apply(event: .failure(
                sessionId: firstSessionID,
                pipelineID: .v7(),
                sourceLabel: "mic",
                message: "Recognition unavailable"
            ))

            store.start(sessionId: firstSessionID)
            #expect(store.segments.count == 1)
            #expect(store.failureMessage == "Recognition unavailable")

            store.start(sessionId: secondSessionID)
            #expect(store.activeSessionId == secondSessionID)
            #expect(store.segments.isEmpty)
            #expect(store.failureMessage == nil)

            store.clear()
            #expect(store.activeSessionId == nil)
            #expect(store.segments.isEmpty)
            #expect(store.failureMessage == nil)
        }

        private func makeSegment(
            id: UUID = .v7(),
            sessionID: UUID,
            text: String,
            source: String?,
            isConfirmed: Bool = false
        ) -> TranscriptSegment {
            TranscriptSegment(
                id: id,
                sessionId: sessionID,
                startTime: Date(timeIntervalSince1970: 1_776_384_000),
                text: text,
                isConfirmed: isConfirmed,
                speakerLabel: source
            )
        }

        private func segmentWithConfirmation(_ segment: TranscriptSegment) -> TranscriptSegment {
            TranscriptSegment(
                id: segment.id,
                sessionId: segment.sessionId,
                startTime: segment.startTime,
                endTime: segment.endTime,
                text: segment.text,
                translatedText: segment.translatedText,
                isConfirmed: true,
                speakerLabel: segment.speakerLabel
            )
        }
    }
#endif
