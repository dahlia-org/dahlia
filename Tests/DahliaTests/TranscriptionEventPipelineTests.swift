#if canImport(Testing)
    // swiftlint:disable file_length
    import Foundation
    import Testing
    @testable import Dahlia

    // swiftlint:disable:next type_body_length
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
            await uiEvents.waitForCount(2)
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
            await uiEvents.waitForCount(2)
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
        func controlBacklogIsBoundedAndLatestWinsPerSemanticTarget() async throws {
            let uiGate = AsyncTestGate()
            let uiEvents = TranscriptionEventProbe()
            let sessionID = UUID.v7()
            let segmentID = UUID.v7()
            let blockingEvent = TranscriptionEvent.failure(
                sessionId: sessionID,
                pipelineID: .v7(),
                sourceLabel: "mic",
                message: "block UI"
            )
            let pipeline = TranscriptionEventPipeline(
                uiSink: { events in
                    await uiEvents.append(contentsOf: events)
                    await uiGate.wait()
                },
                persistenceSink: { _ in }
            )

            await pipeline.start()
            await pipeline.enqueue(blockingEvent)
            await uiEvents.waitForCount(1)
            for index in 0 ..< 1_000 {
                await pipeline.enqueue(.previewTranslation(
                    sessionId: sessionID,
                    segmentID: segmentID,
                    translatedText: "translation-\(index)"
                ))
            }
            let latestFailure = TranscriptionEvent.failure(
                sessionId: sessionID,
                pipelineID: .v7(),
                sourceLabel: "system",
                message: "failure-999"
            )
            for index in 0 ..< 999 {
                await pipeline.enqueue(.failure(
                    sessionId: sessionID,
                    pipelineID: .v7(),
                    sourceLabel: "system",
                    message: "failure-\(index)"
                ))
            }
            await pipeline.enqueue(latestFailure)
            await uiGate.open()
            await uiEvents.waitForCount(3)
            try await pipeline.finish()

            let delivered = await uiEvents.snapshot()
            #expect(delivered.count == 3)
            #expect(delivered.contains(.previewTranslation(
                sessionId: sessionID,
                segmentID: segmentID,
                translatedText: "translation-999"
            )))
            #expect(delivered.contains(latestFailure))
        }

        @Test
        func previewQueuedAtCompactionBoundaryIsDelivered() async throws {
            let uiGate = AsyncTestGate()
            let uiEvents = TranscriptionEventProbe()
            let sessionID = UUID.v7()
            let blockingEvent = TranscriptionEvent.failure(
                sessionId: sessionID,
                pipelineID: .v7(),
                sourceLabel: "mic",
                message: "block UI"
            )
            let preview = TranscriptionEvent.preview(
                makeSegment(sessionId: sessionID, text: "latest preview", isConfirmed: false)
            )
            let pipeline = TranscriptionEventPipeline(
                uiSink: { events in
                    await uiEvents.append(contentsOf: events)
                    await uiGate.wait()
                },
                persistenceSink: { _ in }
            )

            await pipeline.start()
            await pipeline.enqueue(blockingEvent)
            await uiEvents.waitForCount(1)
            for index in 0 ..< TranscriptionEventPipeline.maximumPendingUIEventCount {
                await pipeline.enqueue(.finalized(TranscriptSegment(
                    startTime: Date(timeIntervalSince1970: Double(index)),
                    text: "final-\(index)",
                    isConfirmed: true
                )))
            }
            await pipeline.enqueue(preview)

            await uiGate.open()
            await uiEvents.waitForCount(2)
            try await pipeline.finish()

            #expect(await uiEvents.snapshot().contains(preview))
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
            try await pipeline.resetPersistence()
            try await pipeline.finish()

            #expect(await operations.snapshot() == ["persist", "reset"])
        }

        @Test
        // swiftlint:disable:next function_body_length
        func uiBacklogCompactsToReloadWhilePersistenceRemainsLossless() async throws {
            let uiGate = AsyncTestGate()
            let persistenceGate = AsyncTestGate()
            let uiEvents = TranscriptionEventProbe()
            let persistedEvents = TranscriptionEventProbe()
            let reloads = IntegerProbe()
            let operations = StringProbe()
            let sessionID = UUID.v7()
            let blockingEvent = TranscriptionEvent.failure(
                sessionId: sessionID,
                pipelineID: .v7(),
                sourceLabel: "mic",
                message: "block UI"
            )
            let retainedFailure = TranscriptionEvent.failure(
                sessionId: sessionID,
                pipelineID: .v7(),
                sourceLabel: "system",
                message: "must survive compaction"
            )
            let pipeline = TranscriptionEventPipeline(
                uiSink: { events in
                    await uiEvents.append(contentsOf: events)
                    await uiGate.wait()
                },
                uiReloadSink: {
                    await operations.append("reload")
                    await reloads.increment()
                },
                persistenceSink: { events in
                    await persistedEvents.append(contentsOf: events)
                    await persistenceGate.wait()
                    await operations.append("persisted")
                }
            )

            await pipeline.start()
            await pipeline.enqueue(blockingEvent)
            await uiEvents.waitForCount(1)
            for index in 0 ..< 1_000 {
                if index == 100 {
                    await pipeline.enqueue(retainedFailure)
                }
                await pipeline.enqueue(.finalized(TranscriptSegment(
                    startTime: Date(timeIntervalSince1970: 1_776_384_000 + Double(index)),
                    text: "final-\(index)",
                    isConfirmed: true,
                    speakerLabel: "mic"
                )))
            }

            await persistedEvents.waitForCount(1)
            await uiGate.open()
            #expect(await reloads.value() == 0)
            await persistenceGate.open()
            await reloads.waitForValue(1)
            await uiEvents.waitForCount(2)
            try await pipeline.finish()

            #expect(await reloads.value() > 0)
            #expect(await uiEvents.snapshot().contains(retainedFailure))
            #expect(await uiEvents.snapshot().count <= TranscriptionEventPipeline.maximumPendingUIEventCount + 2)
            #expect(await persistedEvents.snapshot().count == 1_000)
            let operationValues = await operations.snapshot()
            let persistedIndex = try #require(operationValues.firstIndex(of: "persisted"))
            let reloadIndex = try #require(operationValues.firstIndex(of: "reload"))
            #expect(persistedIndex < reloadIndex)
        }

        @Test
        func compactedReloadRunsAfterPersistenceRecoversDuringServiceStop() async {
            let uiGate = AsyncTestGate()
            let uiEvents = TranscriptionEventProbe()
            let reloads = IntegerProbe()
            let flushes = RecoverableFlushProbe()
            let pipeline = TranscriptionEventPipeline(
                uiSink: { events in
                    await uiEvents.append(contentsOf: events)
                    await uiGate.wait()
                },
                uiReloadSink: {
                    await reloads.increment()
                },
                persistenceSink: { _ in },
                persistenceFlushSink: {
                    try await flushes.flush()
                }
            )

            await pipeline.start()
            await pipeline.enqueue(.failure(
                sessionId: .v7(),
                pipelineID: .v7(),
                sourceLabel: "mic",
                message: "block UI"
            ))
            await uiEvents.waitForCount(1)
            for index in 0 ..< 1_000 {
                await pipeline.enqueue(.finalized(TranscriptSegment(
                    startTime: Date(timeIntervalSince1970: Double(index)),
                    text: "final-\(index)",
                    isConfirmed: true
                )))
            }
            await uiGate.open()
            await flushes.waitForAttempt()

            do {
                try await pipeline.finish()
                Issue.record("The first flush failure should still be reported")
            } catch {}

            #expect(await flushes.attemptCount() >= 1)
            #expect(await reloads.value() == 0)
            await flushes.recover()
            await pipeline.notifyPersistenceRecoveredAfterFinish()
            await reloads.waitForValue(1)
            #expect(await reloads.value() == 1)
        }

        @Test
        func finishDoesNotWaitIndefinitelyForBlockedUI() async throws {
            let uiGate = AsyncTestGate()
            let uiEvents = TranscriptionEventProbe()
            let pipeline = TranscriptionEventPipeline(
                uiSink: { events in
                    await uiEvents.append(contentsOf: events)
                    await uiGate.wait()
                },
                persistenceSink: { _ in }
            )

            await pipeline.start()
            await pipeline.enqueue(.failure(
                sessionId: .v7(),
                pipelineID: .v7(),
                sourceLabel: "mic",
                message: "block UI forever"
            ))
            await uiEvents.waitForCount(1)
            let flushTask = Task {
                await pipeline.flushUI()
            }
            await Task.yield()

            let clock = ContinuousClock()
            let elapsed = try await clock.measure {
                try await pipeline.finish()
            }
            #expect(elapsed < TranscriptionEventPipeline.maximumUIFinishWait + .seconds(1))
            await flushTask.value
            await uiGate.open()
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

    private actor IntegerProbe {
        private var count = 0
        private var waiters: [(value: Int, continuation: CheckedContinuation<Void, Never>)] = []

        func increment() {
            count += 1
            let satisfied = waiters.filter { count >= $0.value }
            waiters.removeAll { count >= $0.value }
            satisfied.forEach { $0.continuation.resume() }
        }

        func value() -> Int {
            count
        }

        func waitForValue(_ value: Int) async {
            guard count < value else { return }
            await withCheckedContinuation { continuation in
                waiters.append((value, continuation))
            }
        }
    }

    private actor RecoverableFlushProbe {
        private enum ExpectedFailure: Error {
            case transient
        }

        private var attempts = 0
        private var isRecovered = false
        private var attemptWaiters: [CheckedContinuation<Void, Never>] = []

        func flush() throws {
            attempts += 1
            let waiters = attemptWaiters
            attemptWaiters.removeAll()
            waiters.forEach { $0.resume() }
            if !isRecovered {
                throw ExpectedFailure.transient
            }
        }

        func recover() {
            isRecovered = true
        }

        func attemptCount() -> Int {
            attempts
        }

        func waitForAttempt() async {
            guard attempts == 0 else { return }
            await withCheckedContinuation { continuation in
                attemptWaiters.append(continuation)
            }
        }
    }
#endif
