import FluidAudio
import Foundation
import os
@testable import Dahlia

// swiftlint:disable file_length
#if canImport(Testing)
    import Testing

    private let lifecycleWaitTimeout = testPollTimeout

    // swiftlint:disable:next type_body_length
    struct SpeakerDiarizationRuntimeTests {
        @Test
        func concurrentExtractsQueueBehindOneLoadAndBothSucceed() async throws {
            let probe = SerialDiarizerProbe(output: SpeakerDiarizationOutput(
                chunks: [chunk(speakerID: "S1", embedding: unitVector(index: 0))],
                speakerDatabase: [:]
            ))
            let extractor = FluidAudioSpeakerEmbeddingExtractor(
                processor: ProbedSpeakerDiarizationProcessor(probe: probe),
                space: space(),
                loadHook: { try await probe.load() }
            )
            let source = try sampleSource(samples: [], sampleRate: 16000)
            defer { try? source.cleanup() }

            let first = Task { try await extractor.extract(from: source) }
            try #require(await probe.waitUntilFirstProcessStarts(), "The first diarization request did not start")
            let second = Task { try await extractor.extract(from: source) }
            await Task.yield()
            await probe.releaseFirstProcess()

            #expect(try await awaitLifecycleTask(first, "first concurrent request").count == 1)
            #expect(try await awaitLifecycleTask(second, "second concurrent request").count == 1)
            let counts = await probe.counts()
            #expect(counts.load == 1)
            #expect(counts.process == 2)
            #expect(counts.maximumConcurrent == 1)
            _ = try await awaitLifecycleTask(Task { await extractor.shutdown() }, "concurrent extractor shutdown")
        }

        @Test
        func scopedExtractorStopsWorkerAndReleasesProcessor() async throws {
            let releaseProbe = ReleaseProbe()
            let source = try sampleSource(samples: [], sampleRate: 16000)
            defer { try? source.cleanup() }

            let weakProcessor = try await runScopedExtractor(source: source, releaseProbe: releaseProbe)
            try #require(
                await releaseProbe.waitUntilReleased(),
                "Processor leaked after its extractor left scope"
            )

            #expect(weakProcessor.value == nil)
        }

        @Test
        func everyTeardownPathLeavesNoOrphanedWorker() async throws {
            let source = try sampleSource(samples: [], sampleRate: 16000)
            defer { try? source.cleanup() }
            let normal = try await runTeardownPath(.normalScope, source: source)
            let explicit = try await runTeardownPath(.explicitShutdown, source: source)
            let loadFailure = try await runTeardownPath(.loadFailure, source: source)
            let cancellation = try await runTeardownPath(.cancellation, source: source)
            let shutdownRace = try await runTeardownPath(.shutdownRace, source: source)
            let paths = [
                "normalScope": normal,
                "explicitShutdown": explicit,
                "loadFailure": loadFailure,
                "cancellation": cancellation,
                "shutdownRace": shutdownRace,
            ]

            for (name, path) in paths {
                #expect(
                    await path.releaseProbe.waitUntilReleased(),
                    "Processor leaked after the \(name) teardown path"
                )
                #expect(path.processor.value == nil)
            }
        }

        @Test
        func failedLoadIsRetriedByLaterExtract() async throws {
            let probe = SerialDiarizerProbe(output: SpeakerDiarizationOutput(
                chunks: [chunk(speakerID: "S1", embedding: unitVector(index: 0))],
                speakerDatabase: [:]
            ))
            let extractor = FluidAudioSpeakerEmbeddingExtractor(
                processor: ProbedSpeakerDiarizationProcessor(probe: probe),
                space: space(),
                loadHook: { try await probe.loadFailingFirstAttempt() }
            )
            let source = try sampleSource(samples: [], sampleRate: 16000)
            defer { try? source.cleanup() }

            await #expect(throws: LoadBoom.self) {
                try await extractor.extract(from: source)
            }
            let retry = Task { try await extractor.extract(from: source) }
            try #require(await probe.waitUntilFirstProcessStarts(), "The retry diarization request did not start")
            await probe.releaseFirstProcess()
            let evidence = try await awaitLifecycleTask(retry, "request after a failed load")

            #expect(evidence.count == 1)
            let counts = await probe.counts()
            #expect(counts.load == 2)
            #expect(counts.process == 1)
            _ = try await awaitLifecycleTask(Task { await extractor.shutdown() }, "extractor shutdown after load retry")
        }

        @Test
        func completedTicketDoesNotStartDiarizationWork() async throws {
            let source = try sampleSource(samples: [], sampleRate: 16000)
            defer { try? source.cleanup() }
            let ticket = RequestTicket()
            ticket.cancel()
            let request = SerialDiarizerHost.Request(source: source, ticket: ticket)
            let probe = CompletionProbe()
            let taskCreationProbe = TaskCreationProbe()

            _ = await SerialDiarizerHost.processRequest(
                request,
                operation: { _ in await probe.process() },
                makeTask: { operation in
                    taskCreationProbe.markCreated()
                    return Task { try await operation() }
                }
            )

            #expect(taskCreationProbe.createdCount == 0, "A diarization task was created for an already-completed ticket")
            #expect(
                !(await probe.waitUntilCompleted(timeout: .seconds(1))),
                "Diarization work ran to completion after its request ticket had already completed"
            )
            #expect(await probe.completedCount == 0)
        }

        @Test
        func cancellationDuringTaskCreationCancelsTaskBeforeItStarts() async throws {
            let source = try sampleSource(samples: [], sampleRate: 16000)
            defer { try? source.cleanup() }
            let ticket = RequestTicket()
            let request = SerialDiarizerHost.Request(source: source, ticket: ticket)
            let probe = CompletionProbe()

            let result = await SerialDiarizerHost.processRequest(
                request,
                operation: { _ in await probe.process() },
                makeTask: { operation in
                    ticket.cancel()
                    return Task { try await operation() }
                }
            )
            let wasCancelled: Bool
            if case let .failure(error)? = result {
                wasCancelled = error is CancellationError
            } else {
                wasCancelled = false
            }

            #expect(wasCancelled, "A diarization task cancelled during creation did not report cancellation")
            #expect(await probe.completedCount == 0, "Diarization work completed after cancellation during task creation")
        }

        @Test
        func transientLoadFailureRemainsSingleFlightAtEveryMeasuredWidth() async throws {
            let source = try sampleSource(samples: [], sampleRate: 16000)
            defer { try? source.cleanup() }

            for callerCount in [2, 4, 8, 16] {
                let probe = TransientFailureConcurrencyProbe(output: emptyOutput())
                let host = SerialDiarizerHost(
                    processor: TransientFailureProcessor(probe: probe),
                    loadHook: { try await probe.load() }
                )
                let barrier = AsyncBarrier(participantCount: callerCount)
                let callers = (0 ..< callerCount).map { _ in
                    Task {
                        await barrier.arrive()
                        do {
                            _ = try await host.process(source: source)
                            return false
                        } catch is LoadBoom {
                            return true
                        } catch {
                            return false
                        }
                    }
                }
                try #require(
                    await probe.waitUntilFirstLoadStarts(),
                    "The first diarizer load did not start"
                )
                for _ in 0 ..< callerCount * 4 {
                    await Task.yield()
                }
                await probe.releaseFirstLoad()

                for caller in callers {
                    #expect(try await awaitLifecycleTask(caller, "caller waiting for the failed load"))
                }
                let retries = (0 ..< callerCount).map { _ in
                    Task { try await host.process(source: source) }
                }
                for retry in retries {
                    _ = try await awaitLifecycleTask(retry, "caller waiting for serialized diarization")
                }
                let counts = await probe.counts()
                #expect(counts.loads == 2)
                #expect(counts.maximumLiveLoadedWorkers == 1)
                #expect(counts.maximumConcurrentProcesses == 1)
                print(
                    "DIARIZER_TRANSIENT callers=\(callerCount) loads=\(counts.loads) "
                        + "maxLiveLoadedWorkers=\(counts.maximumLiveLoadedWorkers) "
                        + "maxConcurrentProcesses=\(counts.maximumConcurrentProcesses)"
                )
                _ = try await awaitLifecycleTask(Task { await host.shutdown() }, "host shutdown after transient load failure")
            }
        }

        @Test
        func cancellingInFlightExtractStopsProcessorPromptly() async throws {
            let probe = CancellationProbe()
            let extractor = FluidAudioSpeakerEmbeddingExtractor(
                processor: CancellableSpeakerDiarizationProcessor(probe: probe),
                space: space()
            )
            let source = try sampleSource(samples: [], sampleRate: 16000)
            defer { try? source.cleanup() }
            let clock = ContinuousClock()
            let startedAt = clock.now
            let extraction = Task { try await extractor.extract(from: source) }
            try #require(await probe.waitUntilStarted(), "Diarization did not start")

            extraction.cancel()
            await #expect(throws: CancellationError.self) {
                try await awaitLifecycleTask(extraction, "cancelled in-flight extraction")
            }
            try #require(await probe.waitUntilCancelled(), "Cancelled diarization work did not stop")

            #expect(startedAt.duration(to: clock.now) < .seconds(1))
            #expect(await probe.processCount == 1)
            _ = try await awaitLifecycleTask(Task { await extractor.shutdown() }, "extractor shutdown after cancellation")
        }

        @Test
        func cancellingQueuedExtractRemovesItWithoutInterruptingActiveWork() async throws {
            let probe = SerialDiarizerProbe(output: SpeakerDiarizationOutput(
                chunks: [chunk(speakerID: "S1", embedding: unitVector(index: 0))],
                speakerDatabase: [:]
            ))
            let extractor = FluidAudioSpeakerEmbeddingExtractor(
                processor: ProbedSpeakerDiarizationProcessor(probe: probe),
                space: space(),
                loadHook: { try await probe.load() }
            )
            let source = try sampleSource(samples: [], sampleRate: 16000)
            defer { try? source.cleanup() }
            let active = Task { try await extractor.extract(from: source) }
            try #require(await probe.waitUntilFirstProcessStarts(), "The active diarization request did not start")
            let queued = Task { try await extractor.extract(from: source) }
            await Task.yield()

            queued.cancel()
            await #expect(throws: CancellationError.self) {
                try await awaitLifecycleTask(queued, "cancelled queued extraction")
            }
            await probe.releaseFirstProcess()
            #expect(try await awaitLifecycleTask(active, "active extraction after queued cancellation").count == 1)

            let counts = await probe.counts()
            #expect(counts.process == 1)
            _ = try await awaitLifecycleTask(Task { await extractor.shutdown() }, "extractor shutdown after queued cancellation")
        }

        @Test
        func cancellingActiveRequestDoesNotCancelQueuedRequests() async throws {
            let probe = ActiveCancellationProbe(output: emptyOutput())
            let host = SerialDiarizerHost(processor: ActiveCancellationProcessor(probe: probe))
            let source = try sampleSource(samples: [], sampleRate: 16000)
            defer { try? source.cleanup() }
            let active = Task { try await host.process(source: source) }
            try #require(await probe.waitUntilFirstProcessStarts(), "The active diarization request did not start")
            let queued = (0 ..< 3).map { _ in
                Task { try await host.process(source: source) }
            }
            for _ in 0 ..< 12 {
                await Task.yield()
            }

            active.cancel()
            await #expect(throws: CancellationError.self) {
                try await awaitLifecycleTask(active, "cancelled active request")
            }
            var outcomes: [String] = []
            for caller in queued {
                do {
                    _ = try await awaitLifecycleTask(caller, "queued request after active cancellation")
                    outcomes.append("success")
                } catch {
                    outcomes.append(String(describing: type(of: error)))
                }
            }

            #expect(outcomes == ["success", "success", "success"])
            #expect(await probe.processCount == 4)
            let maximumConcurrentProcessCount = await probe.maximumConcurrentProcessCount
            #expect(
                maximumConcurrentProcessCount == 1,
                "Diarization processed \(maximumConcurrentProcessCount) active requests concurrently"
            )
            print("DIARIZER_ACTIVE_CANCEL queuedOutcomes=\(outcomes)")
            _ = try await awaitLifecycleTask(Task { await host.shutdown() }, "host shutdown after active cancellation")
        }

        @Test
        func shutdownIsTerminalAndDoesNotLeakWhenRacingRequest() async throws {
            let source = try sampleSource(samples: [], sampleRate: 16000)
            defer { try? source.cleanup() }
            var leaks = 0

            for _ in 0 ..< 30 {
                let probe = ShutdownRaceProbe()
                let host = SerialDiarizerHost(
                    processor: ShutdownRaceProcessor(probe: probe),
                    loadHook: { await probe.load() }
                )
                let active = Task { try await host.process(source: source) }
                try #require(await probe.waitUntilProcessStarts(), "Diarization did not start before the shutdown race")
                let shutdown = Task { await host.shutdown() }
                let racing = Task { try await host.process(source: source) }
                let stopped = await probe.waitUntilStopped()
                if !stopped {
                    Issue.record("Diarization work remained active after shutdown")
                    active.cancel()
                    racing.cancel()
                }
                _ = try await awaitLifecycleTask(shutdown, "shutdown racing an active request")
                _ = try? await awaitLifecycleTask(active, "active request during shutdown")
                _ = try? await awaitLifecycleTask(racing, "racing request during shutdown")
                if await probe.activeProcessCount != 0 {
                    leaks += 1
                }
                let loadsBeforeRejectedRequest = await probe.loadCount
                await #expect(throws: SerialDiarizerHostError.shutDown) {
                    try await host.process(source: source)
                }
                #expect(await probe.loadCount == loadsBeforeRejectedRequest)
                if !stopped { return }
            }

            #expect(leaks == 0)
            print("DIARIZER_SHUTDOWN_RACE leaks=\(leaks)/30")
        }

        @Test
        func pipelineFingerprintIgnoresOutputOnlyFields() {
            let baseline = FluidAudioSpeakerEmbeddingExtractor.diarizationConfiguration()
            let fingerprint = SpeakerModelAssetManager.pipelineFingerprint(configuration: baseline)
            var changedExportPath = baseline
            changedExportPath.export.embeddingsPath = "/tmp/debug-embeddings.json"
            var changedOutputShaping = baseline
            changedOutputShaping.exposeChunkEmbeddings.toggle()
            var changedEmbeddingPipeline = baseline
            changedEmbeddingPipeline.embedding.minSegmentDurationSeconds = 0.3

            #expect(SpeakerModelAssetManager.pipelineFingerprint(configuration: changedExportPath) == fingerprint)
            #expect(SpeakerModelAssetManager.pipelineFingerprint(configuration: changedOutputShaping) == fingerprint)
            #expect(SpeakerModelAssetManager.pipelineFingerprint(configuration: changedEmbeddingPipeline) != fingerprint)
            #expect(fingerprint == "940b0cc57514e75db9733e5ba3fce2699974b7815cdcc3781fd9d90ad813f300")
            print("DIARIZER_FINGERPRINT hash=\(fingerprint)")
        }

        @MainActor
        @Test
        func exemplarSelectionPrefersNewMeetingOverNewAudioSource() async throws {
            let fixture = try SpeakerIdentityFixture()
            let first = try fixture.addSpeaker(values: unitVector(index: 0), source: .microphone, quality: 1)
            let sameMeetingNewSource = try fixture.addSpeaker(
                meetingId: first.meetingId,
                values: unitVector(index: 1),
                source: .system,
                quality: 0.9
            )
            let newMeetingSameSource = try fixture.addSpeaker(
                values: unitVector(index: 2),
                source: .microphone,
                quality: 0.8
            )
            for speaker in [first, sameMeetingNewSource, newMeetingSameSource] {
                _ = try await fixture.repository.manuallyAssignSpeaker(
                    meetingSpeakerId: speaker.speakerId,
                    contactId: fixture.firstContactId,
                    vaultId: fixture.vaultId,
                    expectedRevision: 1
                )
            }

            let selected = try fixture.profileExemplarSpeakerIds(contactId: fixture.firstContactId)

            #expect(selected == [first.speakerId, newMeetingSameSource.speakerId, sameMeetingNewSource.speakerId])
        }

        @Test
        func outputConversionIntersectsTimelinesAndMeasuresSelectedSamples() throws {
            let source = try sampleSource(
                samples: [1, -1, 0.3, -0.4, 1, -1, 0.999, -1, 0, 1],
                sampleRate: 10
            )
            defer { try? source.cleanup() }
            let embedding = unitVector(index: 7)
            let result = DiarizationResult(
                segments: [
                    segment(speakerID: "S1", start: 0, end: 0.35, quality: 0.2),
                    segment(speakerID: "S1", start: 0.55, end: 1.0, quality: 0.8),
                    segment(speakerID: "S2", start: 0, end: 1.0, quality: 1.0),
                ],
                speakerDatabase: ["S1": embedding],
                chunkEmbeddings: [
                    ChunkEmbedding(
                        speakerId: "S1",
                        chunkIndex: 0,
                        speakerIndex: 0,
                        startTimeSeconds: 0.15,
                        endTimeSeconds: 0.85,
                        embedding256: embedding
                    ),
                ]
            )

            let output = try FluidAudioSpeakerEmbeddingExtractor.makeOutput(from: result, source: source)
            let converted = try #require(output.chunks.first)

            #expect(output.chunks.count == 1)
            #expect(output.speakerDatabase == ["S1": embedding])
            #expect(abs(converted.durationSeconds - 0.5) < 0.000_001)
            #expect(abs(converted.rms - Float(sqrt(2.248_001 / 5))) < 0.000_001)
            #expect(abs(converted.clippingRatio - 0.4) < 0.000_001)
            #expect(abs(converted.segmentQuality - 0.56) < 0.000_001)
        }

        @Test
        func outputConversionDropsChunksWithoutMatchingTimeIntersection() throws {
            let source = try sampleSource(samples: [0.5, 0.5], sampleRate: 10)
            defer { try? source.cleanup() }
            let result = DiarizationResult(
                segments: [segment(speakerID: "S2", start: 0, end: 0.2, quality: 1)],
                chunkEmbeddings: [
                    ChunkEmbedding(
                        speakerId: "S1",
                        chunkIndex: 0,
                        speakerIndex: 0,
                        startTimeSeconds: 0,
                        endTimeSeconds: 0.2,
                        embedding256: unitVector(index: 0)
                    ),
                ]
            )

            let output = try FluidAudioSpeakerEmbeddingExtractor.makeOutput(from: result, source: source)

            #expect(output.chunks.isEmpty)
        }

        @Test
        func productionQualityThresholdsRejectConvertedLowRMSAndClippedChunks() throws {
            let source = try sampleSource(
                samples: [Float](repeating: 0.005, count: 10) + [1] + [Float](repeating: 0.02, count: 9),
                sampleRate: 10
            )
            defer { try? source.cleanup() }
            let result = DiarizationResult(
                segments: [
                    segment(speakerID: "S1", start: 0, end: 1, quality: 1),
                    segment(speakerID: "S2", start: 1, end: 2, quality: 1),
                ],
                chunkEmbeddings: [
                    ChunkEmbedding(
                        speakerId: "S1",
                        chunkIndex: 0,
                        speakerIndex: 0,
                        startTimeSeconds: 0,
                        endTimeSeconds: 1,
                        embedding256: unitVector(index: 0)
                    ),
                    ChunkEmbedding(
                        speakerId: "S2",
                        chunkIndex: 1,
                        speakerIndex: 0,
                        startTimeSeconds: 1,
                        endTimeSeconds: 2,
                        embedding256: unitVector(index: 1)
                    ),
                ]
            )

            let output = try FluidAudioSpeakerEmbeddingExtractor.makeOutput(from: result, source: source)
            let evidence = MeetingSpeakerEvidenceBuilder.build(
                output: output,
                space: space(),
                qualityPolicy: .production
            )

            #expect(output.chunks[0].rms < SpeakerEmbeddingQualityPolicy.production.minimumRMS)
            #expect(output.chunks[1].clippingRatio > SpeakerEmbeddingQualityPolicy.production.maximumClippingRatio)
            #expect(evidence.isEmpty)
        }
    }

    private struct ProbedSpeakerDiarizationProcessor: SpeakerDiarizationProcessing {
        let probe: SerialDiarizerProbe

        func process(source _: MemoryMappedAudioSampleSource) async throws -> SpeakerDiarizationOutput {
            try await probe.process()
        }
    }

    private struct CancellableSpeakerDiarizationProcessor: SpeakerDiarizationProcessing {
        let probe: CancellationProbe

        func process(source _: MemoryMappedAudioSampleSource) async throws -> SpeakerDiarizationOutput {
            try await probe.process()
        }
    }

    private struct TransientFailureProcessor: SpeakerDiarizationProcessing {
        let probe: TransientFailureConcurrencyProbe

        func process(source _: MemoryMappedAudioSampleSource) async throws -> SpeakerDiarizationOutput {
            await probe.process()
        }
    }

    private struct ActiveCancellationProcessor: SpeakerDiarizationProcessing {
        let probe: ActiveCancellationProbe

        func process(source _: MemoryMappedAudioSampleSource) async throws -> SpeakerDiarizationOutput {
            try await probe.process()
        }
    }

    private struct ShutdownRaceProcessor: SpeakerDiarizationProcessing {
        let probe: ShutdownRaceProbe

        func process(source _: MemoryMappedAudioSampleSource) async throws -> SpeakerDiarizationOutput {
            try await probe.process()
        }
    }

    private final class ReleasableSpeakerDiarizationProcessor: SpeakerDiarizationProcessing, Sendable {
        private let releaseProbe: ReleaseProbe
        private let operation: @Sendable () async throws -> SpeakerDiarizationOutput

        init(
            releaseProbe: ReleaseProbe,
            operation: @escaping @Sendable () async throws -> SpeakerDiarizationOutput = { emptyOutput() }
        ) {
            self.releaseProbe = releaseProbe
            self.operation = operation
        }

        func process(source _: MemoryMappedAudioSampleSource) async throws -> SpeakerDiarizationOutput {
            try await operation()
        }

        deinit {
            let releaseProbe = releaseProbe
            Task { await releaseProbe.markReleased() }
        }
    }

    private final class WeakBox<Value: AnyObject>: @unchecked Sendable {
        weak var value: Value?

        init(_ value: Value) {
            self.value = value
        }
    }

    private actor ReleaseProbe {
        private var released = false

        func markReleased() {
            released = true
        }

        func waitUntilReleased() async -> Bool {
            await pollUntil(timeout: lifecycleWaitTimeout) { self.released }
        }
    }

    private actor CompletionProbe {
        private(set) var completedCount = 0

        func process() -> SpeakerDiarizationOutput {
            completedCount += 1
            return emptyOutput()
        }

        func waitUntilCompleted(timeout: Duration) async -> Bool {
            await pollUntil(timeout: timeout) { self.completedCount > 0 }
        }
    }

    private final class TaskCreationProbe: Sendable {
        private let count = OSAllocatedUnfairLock(initialState: 0)

        var createdCount: Int {
            count.withLock { $0 }
        }

        func markCreated() {
            count.withLock { $0 += 1 }
        }
    }

    private final class LifecycleTaskProbe<Success: Sendable, Failure: Error & Sendable>: Sendable {
        private let storedResult = OSAllocatedUnfairLock<Result<Success, Failure>?>(initialState: nil)

        var result: Result<Success, Failure>? {
            storedResult.withLock { $0 }
        }

        func complete(with result: Result<Success, Failure>) {
            storedResult.withLock { $0 = result }
        }
    }

    private struct LifecycleTaskTimeout: Error {
        let description: String
    }

    private func awaitLifecycleTask<Success: Sendable, Failure: Error & Sendable>(
        _ task: Task<Success, Failure>,
        _ description: String
    ) async throws -> Success {
        let probe = LifecycleTaskProbe<Success, Failure>()
        let observer = Task { probe.complete(with: await task.result) }
        guard await pollUntil(timeout: lifecycleWaitTimeout, { probe.result != nil }) else {
            task.cancel()
            observer.cancel()
            throw LifecycleTaskTimeout(description: description)
        }
        await observer.value
        guard let result = probe.result else { throw LifecycleTaskTimeout(description: description) }
        return try result.get()
    }

    private actor CancellationProbe {
        private(set) var processCount = 0
        private var started = false
        private var cancelled = false

        func process() async throws -> SpeakerDiarizationOutput {
            processCount += 1
            started = true
            do {
                try await Task.sleep(for: .seconds(30))
                return SpeakerDiarizationOutput(chunks: [], speakerDatabase: [:])
            } catch {
                cancelled = true
                throw error
            }
        }

        func waitUntilStarted() async -> Bool {
            await pollUntil(timeout: lifecycleWaitTimeout) { self.started }
        }

        func waitUntilCancelled() async -> Bool {
            await pollUntil(timeout: lifecycleWaitTimeout) { self.cancelled }
        }
    }

    private actor AsyncBarrier {
        private let participantCount: Int
        private var arrivedCount = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(participantCount: Int) {
            self.participantCount = participantCount
        }

        func arrive() async {
            arrivedCount += 1
            if arrivedCount == participantCount {
                let waiters = waiters
                self.waiters.removeAll()
                waiters.forEach { $0.resume() }
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private actor TransientFailureConcurrencyProbe {
        private let output: SpeakerDiarizationOutput
        private var loadCount = 0
        private var liveLoadedWorkerCount = 0
        private var maximumLiveLoadedWorkerCount = 0
        private var activeProcessCount = 0
        private var maximumConcurrentProcessCount = 0
        private var firstLoadRelease: CheckedContinuation<Void, Never>?

        init(output: SpeakerDiarizationOutput) {
            self.output = output
        }

        func load() async throws {
            loadCount += 1
            if loadCount == 1 {
                await withCheckedContinuation { firstLoadRelease = $0 }
                throw LoadBoom()
            }
            liveLoadedWorkerCount += 1
            maximumLiveLoadedWorkerCount = max(maximumLiveLoadedWorkerCount, liveLoadedWorkerCount)
        }

        func process() async -> SpeakerDiarizationOutput {
            activeProcessCount += 1
            maximumConcurrentProcessCount = max(maximumConcurrentProcessCount, activeProcessCount)
            defer { activeProcessCount -= 1 }
            for _ in 0 ..< 10 {
                await Task.yield()
            }
            return output
        }

        func waitUntilFirstLoadStarts() async -> Bool {
            await pollUntil(timeout: lifecycleWaitTimeout) { self.loadCount > 0 }
        }

        func releaseFirstLoad() {
            firstLoadRelease?.resume()
            firstLoadRelease = nil
        }

        func counts() -> (loads: Int, maximumLiveLoadedWorkers: Int, maximumConcurrentProcesses: Int) {
            (loadCount, maximumLiveLoadedWorkerCount, maximumConcurrentProcessCount)
        }
    }

    private actor ActiveCancellationProbe {
        private let output: SpeakerDiarizationOutput
        private(set) var processCount = 0
        private(set) var maximumConcurrentProcessCount = 0
        private var activeProcessCount = 0

        init(output: SpeakerDiarizationOutput) {
            self.output = output
        }

        func process() async throws -> SpeakerDiarizationOutput {
            processCount += 1
            activeProcessCount += 1
            maximumConcurrentProcessCount = max(maximumConcurrentProcessCount, activeProcessCount)
            await Task.yield()
            defer { activeProcessCount -= 1 }
            if processCount == 1 {
                try await Task.sleep(for: .seconds(30))
            }
            return output
        }

        func waitUntilFirstProcessStarts() async -> Bool {
            await pollUntil(timeout: lifecycleWaitTimeout) { self.processCount > 0 }
        }
    }

    private actor ShutdownRaceProbe {
        private(set) var loadCount = 0
        private(set) var activeProcessCount = 0

        func load() {
            loadCount += 1
        }

        func process() async throws -> SpeakerDiarizationOutput {
            activeProcessCount += 1
            defer { activeProcessCount -= 1 }
            try await Task.sleep(for: .seconds(30))
            return emptyOutput()
        }

        func waitUntilProcessStarts() async -> Bool {
            await pollUntil(timeout: lifecycleWaitTimeout) { self.activeProcessCount > 0 }
        }

        func waitUntilStopped() async -> Bool {
            await pollUntil(timeout: lifecycleWaitTimeout) { self.activeProcessCount == 0 }
        }
    }

    private actor SerialDiarizerProbe {
        private let output: SpeakerDiarizationOutput
        private var loadCount = 0
        private var processCount = 0
        private var activeProcessCount = 0
        private var maximumConcurrentProcessCount = 0
        private var firstProcessRelease: CheckedContinuation<Void, Never>?

        init(output: SpeakerDiarizationOutput) {
            self.output = output
        }

        func load() throws {
            loadCount += 1
        }

        func loadFailingFirstAttempt() throws {
            loadCount += 1
            if loadCount == 1 {
                throw LoadBoom()
            }
        }

        func process() async throws -> SpeakerDiarizationOutput {
            processCount += 1
            activeProcessCount += 1
            maximumConcurrentProcessCount = max(maximumConcurrentProcessCount, activeProcessCount)
            if processCount == 1 {
                await withCheckedContinuation { continuation in
                    firstProcessRelease = continuation
                }
            }
            activeProcessCount -= 1
            return output
        }

        func waitUntilFirstProcessStarts() async -> Bool {
            await pollUntil(timeout: lifecycleWaitTimeout) { self.processCount > 0 }
        }

        func releaseFirstProcess() {
            firstProcessRelease?.resume()
            firstProcessRelease = nil
        }

        func counts() -> (load: Int, process: Int, maximumConcurrent: Int) {
            (loadCount, processCount, maximumConcurrentProcessCount)
        }
    }

    private struct LoadBoom: Error {}

    private enum TeardownPath {
        case normalScope
        case explicitShutdown
        case loadFailure
        case cancellation
        case shutdownRace
    }

    private func runScopedExtractor(
        source: MemoryMappedAudioSampleSource,
        releaseProbe: ReleaseProbe
    ) async throws -> WeakBox<ReleasableSpeakerDiarizationProcessor> {
        let processor = ReleasableSpeakerDiarizationProcessor(releaseProbe: releaseProbe)
        let weakProcessor = WeakBox(processor)
        let extractor = FluidAudioSpeakerEmbeddingExtractor(
            processor: processor,
            space: space()
        )
        _ = try await extractor.extract(from: source)
        return weakProcessor
    }

    private func runTeardownPath(
        _ path: TeardownPath,
        source: MemoryMappedAudioSampleSource
    ) async throws -> (processor: WeakBox<ReleasableSpeakerDiarizationProcessor>, releaseProbe: ReleaseProbe) {
        let releaseProbe = ReleaseProbe()
        let cancellationProbe = CancellationProbe()
        let processor = switch path {
        case .cancellation, .shutdownRace:
            ReleasableSpeakerDiarizationProcessor(
                releaseProbe: releaseProbe,
                operation: { try await cancellationProbe.process() }
            )
        case .normalScope, .explicitShutdown, .loadFailure:
            ReleasableSpeakerDiarizationProcessor(releaseProbe: releaseProbe)
        }
        let weakProcessor = WeakBox(processor)
        let host = switch path {
        case .loadFailure:
            SerialDiarizerHost(processor: processor, loadHook: { throw LoadBoom() })
        case .normalScope, .explicitShutdown, .cancellation, .shutdownRace:
            SerialDiarizerHost(processor: processor)
        }

        switch path {
        case .normalScope:
            _ = try await host.process(source: source)
        case .explicitShutdown:
            _ = try await host.process(source: source)
            _ = try await awaitLifecycleTask(Task { await host.shutdown() }, "explicit teardown shutdown")
        case .loadFailure:
            _ = try? await host.process(source: source)
        case .cancellation:
            let request = Task { try await host.process(source: source) }
            #expect(
                await cancellationProbe.waitUntilStarted(),
                "Diarization did not start before request cancellation"
            )
            request.cancel()
            _ = try? await awaitLifecycleTask(request, "cancelled teardown request")
            _ = try await awaitLifecycleTask(Task { await host.shutdown() }, "shutdown after request cancellation")
        case .shutdownRace:
            let active = Task { try await host.process(source: source) }
            #expect(
                await cancellationProbe.waitUntilStarted(),
                "Diarization did not start before the shutdown teardown race"
            )
            let shutdown = Task { await host.shutdown() }
            let racing = Task { try await host.process(source: source) }
            let stopped = await cancellationProbe.waitUntilCancelled()
            if !stopped {
                Issue.record("Diarization work leaked after the shutdown teardown race")
                active.cancel()
                racing.cancel()
            }
            _ = try await awaitLifecycleTask(shutdown, "shutdown teardown race")
            _ = try? await awaitLifecycleTask(active, "active shutdown teardown request")
            _ = try? await awaitLifecycleTask(racing, "racing shutdown teardown request")
        }
        return (weakProcessor, releaseProbe)
    }

    private func sampleSource(samples: [Float], sampleRate: Int) throws -> MemoryMappedAudioSampleSource {
        let temporaryURL = FileManager.default.temporaryDirectory.appending(
            path: "dahlia-speaker-samples-\(UUID.v7().uuidString).f32"
        )
        let data = samples.withUnsafeBytes { Data($0) }
        try data.write(to: temporaryURL)
        return try MemoryMappedAudioSampleSource(temporaryFileURL: temporaryURL, sampleRate: sampleRate)
    }

    private func segment(
        speakerID: String,
        start: Float,
        end: Float,
        quality: Float
    ) -> TimedSpeakerSegment {
        TimedSpeakerSegment(
            speakerId: speakerID,
            embedding: [],
            startTimeSeconds: start,
            endTimeSeconds: end,
            qualityScore: quality
        )
    }

    private func chunk(speakerID: String, embedding: [Float]) -> SpeakerEmbeddingChunk {
        SpeakerEmbeddingChunk(
            speakerID: speakerID,
            startTimeSeconds: 0,
            endTimeSeconds: 1.5,
            durationSeconds: 1.5,
            embedding: embedding,
            rms: 0.5,
            clippingRatio: 0,
            segmentQuality: 1
        )
    }

    private func unitVector(index: Int) -> [Float] {
        var values = [Float](repeating: 0, count: 256)
        values[index] = 1
        return values
    }

    private func space() -> SpeakerEmbeddingSpace {
        SpeakerEmbeddingSpace(
            provider: "provider",
            modelName: "model",
            revision: "revision",
            assetFingerprint: "fingerprint",
            fluidAudioVersion: "0.15.5",
            dimensionCount: 256,
            sampleRate: 16000,
            preprocessing: "mono",
            excludesOverlap: true,
            normalization: "L2",
            similarityDefinition: "cosine"
        )
    }

    private func emptyOutput() -> SpeakerDiarizationOutput {
        SpeakerDiarizationOutput(chunks: [], speakerDatabase: [:])
    }
#endif
// swiftlint:enable file_length
