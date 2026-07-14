#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    struct TranscriptionEventPipelineTests {
        @Test
        func persistenceContinuesWhileUISinkIsSuspended() async throws {
            let uiGate = AsyncTestGate()
            let uiEvents = TranscriptionEventProbe()
            let persistedEvents = TranscriptionEventProbe()
            let sessionId = UUID.v7()
            let preview = TranscriptionEvent.preview(
                makeSegment(sessionId: sessionId, text: "preview", isConfirmed: false)
            )
            let finalized = TranscriptionEvent.finalized(
                makeSegment(sessionId: sessionId, text: "final", isConfirmed: true)
            )
            let pipeline = TranscriptionEventPipeline(
                uiSink: { events in
                    await uiEvents.append(contentsOf: events)
                    await uiGate.wait()
                },
                persistenceSink: { events in
                    await persistedEvents.append(contentsOf: events)
                }
            )

            await pipeline.start()
            await pipeline.enqueue(preview)
            await uiEvents.waitForCount(1)
            await pipeline.enqueue(finalized)

            await persistedEvents.waitForCount(1)
            #expect(await persistedEvents.snapshot() == [finalized])

            await uiGate.open()
            try await pipeline.finish()
            #expect(await uiEvents.snapshot() == [preview, finalized])
        }

        @Test
        func previewBacklogKeepsOnlyLatestValuePerSource() async throws {
            let uiGate = AsyncTestGate()
            let uiEvents = TranscriptionEventProbe()
            let persistedEvents = TranscriptionEventProbe()
            let sessionId = UUID.v7()
            let blockingEvent = TranscriptionEvent.failure(
                sessionId: sessionId,
                pipelineID: .v7(),
                sourceLabel: "mic",
                message: "test"
            )
            let firstPreview = TranscriptionEvent.preview(
                makeSegment(sessionId: sessionId, text: "one", isConfirmed: false)
            )
            let secondPreview = TranscriptionEvent.preview(
                makeSegment(sessionId: sessionId, text: "two", isConfirmed: false)
            )
            let latestPreview = TranscriptionEvent.preview(
                makeSegment(sessionId: sessionId, text: "three", isConfirmed: false)
            )
            let pipeline = TranscriptionEventPipeline(
                uiSink: { events in
                    await uiEvents.append(contentsOf: events)
                    await uiGate.wait()
                },
                persistenceSink: { events in
                    await persistedEvents.append(contentsOf: events)
                }
            )

            await pipeline.start()
            await pipeline.enqueue(blockingEvent)
            await uiEvents.waitForCount(1)
            await pipeline.enqueue(firstPreview)
            await pipeline.enqueue(secondPreview)
            await pipeline.enqueue(latestPreview)

            await uiGate.open()
            try await pipeline.finish()

            #expect(await uiEvents.snapshot() == [blockingEvent, latestPreview])
            #expect(await persistedEvents.snapshot().isEmpty)
        }

        @Test
        func previewTranslationStaysOnUILane() async throws {
            let uiEvents = TranscriptionEventProbe()
            let persistedEvents = TranscriptionEventProbe()
            let event = TranscriptionEvent.previewTranslation(
                sessionId: .v7(),
                segmentID: .v7(),
                translatedText: "preview"
            )
            let pipeline = TranscriptionEventPipeline(
                uiSink: { events in
                    await uiEvents.append(contentsOf: events)
                },
                persistenceSink: { events in
                    await persistedEvents.append(contentsOf: events)
                }
            )

            await pipeline.start()
            await pipeline.enqueue(event)
            try await pipeline.finish()

            #expect(await uiEvents.snapshot() == [event])
            #expect(await persistedEvents.snapshot().isEmpty)
        }

        @Test
        func resetRunsAfterEarlierPersistenceEvents() async throws {
            let operations = StringProbe()
            let sessionID = UUID.v7()
            let pipeline = TranscriptionEventPipeline(
                uiSink: { _ in },
                persistenceSink: { _ in
                    await operations.append("persist")
                },
                persistenceResetSink: {
                    await operations.append("reset")
                }
            )

            await pipeline.start()
            await pipeline.enqueue(.finalized(
                makeSegment(sessionId: sessionID, text: "final", isConfirmed: true)
            ))
            await pipeline.resetPersistence()
            try await pipeline.finish()

            #expect(await operations.snapshot() == ["persist", "reset"])
        }

        private func makeSegment(
            sessionId: UUID,
            text: String,
            isConfirmed: Bool
        ) -> TranscriptSegment {
            TranscriptSegment(
                sessionId: sessionId,
                startTime: Date(timeIntervalSince1970: 1_776_384_000),
                text: text,
                isConfirmed: isConfirmed,
                speakerLabel: "mic"
            )
        }
    }

    private actor AsyncTestGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func open() {
            isOpen = true
            let continuations = waiters
            waiters.removeAll()
            continuations.forEach { $0.resume() }
        }
    }

    private actor TranscriptionEventProbe {
        private var events: [TranscriptionEvent] = []
        private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

        func append(contentsOf newEvents: [TranscriptionEvent]) {
            events.append(contentsOf: newEvents)
            resumeSatisfiedWaiters()
        }

        func snapshot() -> [TranscriptionEvent] {
            events
        }

        func waitForCount(_ count: Int) async {
            guard events.count < count else { return }
            await withCheckedContinuation { continuation in
                waiters.append((count, continuation))
            }
        }

        private func resumeSatisfiedWaiters() {
            let satisfied = waiters.filter { events.count >= $0.count }
            waiters.removeAll { events.count >= $0.count }
            satisfied.forEach { $0.continuation.resume() }
        }
    }

    private actor StringProbe {
        private var values: [String] = []

        func append(_ value: String) {
            values.append(value)
        }

        func snapshot() -> [String] {
            values
        }
    }
#endif
