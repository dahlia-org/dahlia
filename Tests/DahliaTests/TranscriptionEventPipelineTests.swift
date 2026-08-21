#if canImport(Testing)
    // swiftlint:disable file_length
    @preconcurrency import AVFoundation
    import Foundation
    import os
    import Testing
    @testable import Dahlia

    // swiftlint:disable:next type_body_length
    struct TranscriptionEventPipelineTests {
        @Test
        func eventObserverReceivesEveryFinalizedEventWhenUILaneCompacts() async throws {
            let uiGate = AsyncTestGate()
            let uiEvents = TranscriptionEventProbe()
            let observedFinalizedCount = OSAllocatedUnfairLock(initialState: 0)
            let pipeline = TranscriptionEventPipeline(
                uiSink: { events in
                    await uiEvents.append(contentsOf: events)
                    await uiGate.wait()
                },
                eventObserver: { event in
                    guard case let .finalized(segment) = event, segment.isConfirmed else { return }
                    observedFinalizedCount.withLock { $0 += 1 }
                },
                persistenceSink: { _ in }
            )

            await pipeline.start()
            await pipeline.enqueue(.failure(
                sessionId: .v7(),
                pipelineID: .v7(),
                sourceLabel: "mic",
                message: "block UI"
            ))
            await uiEvents.waitForCount(1)
            for index in 0 ..< 1000 {
                await pipeline.enqueue(.finalized(TranscriptSegment(
                    startTime: Date(timeIntervalSince1970: Double(index)),
                    text: "final-\(index)",
                    isConfirmed: true
                )))
            }

            #expect(observedFinalizedCount.withLock { $0 } == 1000)
            await uiGate.open()
            try await pipeline.finish()
        }

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
            await uiEvents.waitForCount(1)
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
            for index in 0 ..< 1000 {
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
            let batchSleep = PersistenceBatchSleepProbe()
            let sessionID = UUID.v7()
            let pipeline = TranscriptionEventPipeline(
                uiSink: { _ in },
                persistenceSink: { _ in
                    try Task.checkCancellation()
                    await operations.append("persist")
                },
                persistenceResetSink: {
                    await operations.append("reset")
                },
                persistenceBatchSleep: {
                    try await batchSleep.sleep()
                }
            )

            await pipeline.start()
            await pipeline.enqueue(.finalized(
                makeSegment(sessionId: sessionID, text: "final", isConfirmed: true)
            ))
            await batchSleep.waitUntilStarted()
            try await pipeline.resetPersistence()
            try await pipeline.finish()

            #expect(await operations.snapshot() == ["persist", "reset"])
        }

        @Test
        func finishDoesNotCancelPendingPersistenceBatch() async throws {
            let persistedEvents = TranscriptionEventProbe()
            let batchSleep = PersistenceBatchSleepProbe()
            let event = TranscriptionEvent.finalized(
                makeSegment(sessionId: .v7(), text: "final", isConfirmed: true)
            )
            let pipeline = TranscriptionEventPipeline(
                uiSink: { _ in },
                persistenceSink: { events in
                    try Task.checkCancellation()
                    await persistedEvents.append(contentsOf: events)
                },
                persistenceBatchSleep: {
                    try await batchSleep.sleep()
                }
            )

            await pipeline.start()
            await pipeline.enqueue(event)
            await batchSleep.waitUntilStarted()
            try await pipeline.finish()

            #expect(await persistedEvents.snapshot() == [event])
        }

        @Test
        func batchSleepFailureDoesNotDisablePersistence() async throws {
            let persistedEvents = TranscriptionEventProbe()
            let event = TranscriptionEvent.finalized(
                makeSegment(sessionId: .v7(), text: "final", isConfirmed: true)
            )
            let pipeline = TranscriptionEventPipeline(
                uiSink: { _ in },
                persistenceSink: { events in
                    await persistedEvents.append(contentsOf: events)
                },
                persistenceBatchSleep: {
                    throw PersistenceBatchSleepError.failed
                }
            )

            await pipeline.start()
            await pipeline.enqueue(event)
            await persistedEvents.waitForCount(1)
            try await pipeline.finish()

            #expect(await persistedEvents.snapshot() == [event])
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
            for index in 0 ..< 1000 {
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
            #expect(await persistedEvents.snapshot().count == 1000)
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
            for index in 0 ..< 1000 {
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

        @Test
        func blockedObserverCannotDelayOrReorderDurableIngress() async throws {
            let observerGate = AsyncTestGate()
            let persistedEvents = TranscriptionEventProbe()
            let sessionID = UUID.v7()
            let segment = makeSegment(sessionId: sessionID, text: "final", isConfirmed: true)
            let finalized = TranscriptionEvent.finalized(segment)
            let translation = TranscriptionEvent.translation(
                sessionId: sessionID,
                segmentID: segment.id,
                translatedText: "translated"
            )
            let pipeline = TranscriptionEventPipeline(
                uiSink: { _ in },
                eventObserver: { _ in
                    await observerGate.wait()
                },
                persistenceSink: { events in
                    await persistedEvents.append(contentsOf: events)
                }
            )

            await pipeline.start()
            let finalizedTask = Task {
                await pipeline.enqueue(finalized)
            }
            await persistedEvents.waitForCount(1)
            let translationTask = Task {
                await pipeline.enqueue(translation)
            }
            await persistedEvents.waitForCount(2)

            #expect(await persistedEvents.snapshot() == [finalized, translation])
            try await pipeline.finish()
            await pipeline.enqueue(.finalized(
                makeSegment(sessionId: sessionID, text: "closed", isConfirmed: true)
            ))
            #expect(await persistedEvents.snapshot() == [finalized, translation])

            await observerGate.open()
            await finalizedTask.value
            await translationTask.value
        }

        @Test
        func persistenceMetricsMeasureQueuedBytesWaitAndSinkDuration() async throws {
            let batchGate = AsyncTestGate()
            let sinkGate = AsyncTestGate()
            let persistedEvents = TranscriptionEventProbe()
            let sessionID = UUID.v7()
            let segment = makeSegment(sessionId: sessionID, text: "durable", isConfirmed: true)
            let finalized = TranscriptionEvent.finalized(segment)
            let translation = TranscriptionEvent.translation(
                sessionId: sessionID,
                segmentID: segment.id,
                translatedText: "translated"
            )
            let expectedBytes = finalized.durableTextByteCount + translation.durableTextByteCount
            let pipeline = TranscriptionEventPipeline(
                uiSink: { _ in },
                persistenceSink: { events in
                    await persistedEvents.append(contentsOf: events)
                    await sinkGate.wait()
                },
                persistenceBatchSleep: {
                    await batchGate.wait()
                }
            )

            await pipeline.start()
            await pipeline.enqueue(finalized)
            await pipeline.enqueue(translation)
            let queued = await pipeline.persistenceMetricsSnapshot()
            #expect(queued.queuedEventCount == 2)
            #expect(queued.queuedTextByteCount == expectedBytes)
            #expect(queued.highWaterEventCount == 2)
            #expect(queued.highWaterTextByteCount == expectedBytes)
            #expect(queued.oldestEventAge != nil)

            await batchGate.open()
            await persistedEvents.waitForCount(2)
            let blocked = await pipeline.persistenceMetricsSnapshot()
            #expect(blocked.queuedEventCount == 2)

            await sinkGate.open()
            try await pipeline.finish()
            let drained = await pipeline.persistenceMetricsSnapshot()
            #expect(drained.queuedEventCount == 0)
            #expect(drained.queuedTextByteCount == 0)
            #expect(drained.oldestEventAge == nil)
            #expect(drained.maximumQueueWait > .zero)
            #expect(drained.lastSinkDuration > .zero)
        }

        @Test
        // swiftlint:disable:next function_body_length
        func synchronousMainActorStallDoesNotBlockAudioAcceptanceOrPersistence() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let rootURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-main-actor-stall-\(UUID.v7().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let now = Date(timeIntervalSince1970: 1_776_384_000)
            let vault = VaultRecord(
                id: .v7(),
                path: rootURL.appending(path: "Vault", directoryHint: .isDirectory).path,
                name: "Stall",
                createdAt: now,
                lastOpenedAt: now
            )
            let meeting = MeetingRecord(
                id: .v7(),
                vaultId: vault.id,
                projectId: nil,
                name: "Stall",
                status: .ready,
                createdAt: now,
                updatedAt: now
            )
            let session = RecordingSessionRecord(
                id: .v7(),
                meetingId: meeting.id,
                startedAt: now,
                endedAt: nil,
                duration: nil,
                offsetSeconds: 0,
                createdAt: now,
                updatedAt: now
            )
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try meeting.insert(db)
                try session.insert(db)
            }
            let audioStore = try RecordingAudioStore(
                dbQueue: database.dbQueue,
                managedRootURL: rootURL.appending(path: "Managed", directoryHint: .isDirectory),
                configuration: RecordingAudioStore.Configuration(
                    targetSegmentDuration: .seconds(30),
                    maximumFinalizingSegmentCountPerSource: 2,
                    maximumActiveSegmentDuration: .seconds(600),
                    maximumActiveSegmentByteCount: 64 * 1024 * 1024,
                    minimumAvailableCapacity: 0,
                    capacityCheckInterval: .seconds(5)
                )
            )
            try await audioStore.acquireSessionLease(meetingId: meeting.id, sessionId: session.id)
            let format = try #require(AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16000,
                channels: 1,
                interleaved: false
            ))
            let writer = SegmentedAudioSourceWriter(
                source: .microphone,
                format: format,
                store: audioStore,
                meetingId: meeting.id,
                sessionId: session.id,
                locale: Locale(identifier: "ja_JP"),
                firstSegmentIndex: 0,
                requiredSource: true,
                eventHandler: { _ in }
            )
            try await writer.start(sessionOffsetSeconds: 0)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
            buffer.frameLength = 160

            let uiEvents = TranscriptionEventProbe()
            let liveCaptionEvents = TranscriptionEventProbe()
            let persistedEvents = TranscriptionEventProbe()
            let events = [
                TranscriptionEvent.finalized(
                    makeSegment(sessionId: session.id, text: "continues", isConfirmed: true)
                ),
                TranscriptionEvent.finalized(
                    makeSegment(sessionId: session.id, text: "still continues", isConfirmed: true)
                ),
            ]
            let liveCaptionRelay = LiveCaptionEventRelay { events in
                await liveCaptionEvents.append(contentsOf: events)
            }
            let pipeline = TranscriptionEventPipeline(
                uiSink: { events in
                    await uiEvents.append(contentsOf: events)
                },
                eventObserver: { event in
                    await liveCaptionRelay.enqueue(event)
                },
                persistenceSink: { events in
                    await persistedEvents.append(contentsOf: events)
                }
            )
            await pipeline.start()

            let persistenceReady = AsyncTestGate()
            let startPersistence = AsyncTestGate()
            let persistenceTask = Task.detached(priority: .high) {
                await persistenceReady.open()
                await startPersistence.wait()
                for event in events {
                    await pipeline.enqueue(event)
                }
                await persistedEvents.waitForCount(2)
            }
            await persistenceReady.wait()

            let stall = FiniteMainActorStall()
            let stallWatchdog = Task.detached {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                stall.release()
            }
            defer {
                stallWatchdog.cancel()
                stall.release()
            }
            let exerciseTask = Task.detached {
                let mainActorStarted = await stall.waitUntilStarted()
                writer.appendBuffer(buffer)
                await startPersistence.open()
                await persistenceTask.value
                let result = (
                    mainActorWasBlocked: mainActorStarted && stall.isBlocking,
                    acceptedFrameCount: writer.acceptedFrameCount,
                    uiEvents: await uiEvents.snapshot(),
                    persistedEvents: await persistedEvents.snapshot()
                )
                stall.release()
                return result
            }
            let stallTask = Task { @MainActor in
                stall.block()
            }
            let result = await exerciseTask.value
            await stallTask.value

            #expect(result.mainActorWasBlocked)
            #expect(result.acceptedFrameCount == 160)
            #expect(result.uiEvents.isEmpty)
            #expect(result.persistedEvents == events)

            await uiEvents.waitForCount(2)
            try await pipeline.finish()
            await liveCaptionRelay.finish()
            writer.seal()
            try await writer.finish()
            await audioStore.releaseSessionLease(sessionId: session.id)

            #expect(await uiEvents.snapshot() == events)
            #expect(await liveCaptionEvents.snapshot() == events)
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

    private actor PersistenceBatchSleepProbe {
        private var isStarted = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []

        func sleep() async throws {
            isStarted = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            try await Task.sleep(for: .seconds(60))
        }

        func waitUntilStarted() async {
            guard !isStarted else { return }
            await withCheckedContinuation { continuation in
                startWaiters.append(continuation)
            }
        }
    }

    private enum PersistenceBatchSleepError: Error {
        case failed
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

    private final class FiniteMainActorStall: @unchecked Sendable {
        private struct State {
            var hasStarted = false
            var isBlocking = false
        }

        private let state = OSAllocatedUnfairLock(initialState: State())
        private let releaseSemaphore = DispatchSemaphore(value: 0)

        var isBlocking: Bool {
            state.withLock(\.isBlocking)
        }

        func block() {
            state.withLock { state in
                state.hasStarted = true
                state.isBlocking = true
            }
            releaseSemaphore.wait()
            state.withLock { $0.isBlocking = false }
        }

        func release() {
            releaseSemaphore.signal()
        }

        func waitUntilStarted() async -> Bool {
            await pollUntil { state.withLock(\.hasStarted) }
        }
    }
#endif
