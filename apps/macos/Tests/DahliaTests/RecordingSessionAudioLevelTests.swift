#if canImport(Testing)
    @preconcurrency import AVFoundation
    import CoreMedia
    import Dispatch
    import GRDB
    import os
    import Testing
    @testable import Dahlia

    struct RecordingSessionAudioLevelTests {
        @Test
        @MainActor
        func invalidatedGateDropsDeliveryQueuedOnMainActor() async {
            let deliveryGate = RecordingAudioLevelDeliveryGate()
            let levelRecorder = MeteringLevelRecorder()
            let delivery = Task { @MainActor in
                deliveryGate.deliver(source: .microphone, level: 1) { source, level in
                    levelRecorder.append(source: source, level: level)
                }
            }

            deliveryGate.invalidate()
            await delivery.value

            #expect(levelRecorder.entries.isEmpty)
        }

        @Test
        func replacementPublishesCurrentPipelineLevelAndRejectsRetiredPipeline() async throws {
            let pipelineStore = MeteringPipelineStore()
            let levelRecorder = MeteringLevelRecorder()
            let controller = RecordingSessionController(
                captureFactory: MeteringCaptureFactory(pipelineStore: pipelineStore),
                recognitionFactory: MeteringRecognitionFactory(),
                batchRecordingFactory: UnusedMeteringBatchFactory()
            )
            let sessionID = UUID.v7()
            try await controller.prepare(
                .init(
                    sessionId: sessionID,
                    startedAt: .now,
                    plan: .init(finalMode: .realtime, liveSubtitlesEnabled: false),
                    locale: Locale(identifier: "ja_JP"),
                    sources: [.init(source: .microphone)]
                ),
                onEvent: { _ in },
                onRuntimeFailure: { _, _, _ in },
                onAudioLevel: { source, level in
                    levelRecorder.append(source: source, level: level)
                }
            )
            _ = try await controller.startPrepared()
            let retiredPipeline = try #require(pipelineStore.pipelines(for: .microphone).first)
            let retiredDeliveryGate = try #require(await controller.audioLevelDeliveryGates[.microphone])
            try retiredPipeline.router.route(makeChunk(sample: 0.1, time: 0))
            try await levelRecorder.waitUntilCount(1)

            _ = try await controller.setSource(
                .init(source: .microphone, forcesEchoCancellationForExternalMicrophone: true),
                enabled: true,
                translateSegment: nil
            )
            let currentPipeline = try #require(pipelineStore.pipelines(for: .microphone).last)
            #expect(currentPipeline !== retiredPipeline)

            await retiredDeliveryGate.deliver(source: .microphone, level: 1) { source, level in
                levelRecorder.append(source: source, level: level)
            }
            try retiredPipeline.router.route(makeChunk(sample: 0.9, time: 1))
            try currentPipeline.router.route(makeChunk(sample: 0.3, time: 0))
            try await levelRecorder.waitUntilCount(2)
            let entries = await levelRecorder.entries

            #expect(entries.count == 2)
            #expect(entries.allSatisfy { $0.source == .microphone })
            #expect(try entries[1].level < AudioLevelCalculator.normalizedLevel(
                in: makeChunk(sample: 0.9, time: 0).buffer
            ))

            _ = try await controller.stop()
            await controller.completeStop()
        }

        @Test
        func unexpectedCaptureStopResetsLevelBeforeRecognitionFinishes() async throws {
            let pipelineStore = MeteringPipelineStore()
            let levelRecorder = MeteringLevelRecorder()
            let recognitionFinishGate = MeteringRecognitionFinishGate()
            let controller = RecordingSessionController(
                captureFactory: MeteringCaptureFactory(pipelineStore: pipelineStore),
                recognitionFactory: MeteringRecognitionFactory(finishGate: recognitionFinishGate),
                batchRecordingFactory: UnusedMeteringBatchFactory()
            )
            let sessionID = UUID.v7()
            try await controller.prepare(
                .init(
                    sessionId: sessionID,
                    startedAt: .now,
                    plan: .init(finalMode: .realtime, liveSubtitlesEnabled: false),
                    locale: Locale(identifier: "ja_JP"),
                    sources: [.init(source: .microphone)]
                ),
                onEvent: { _ in },
                onRuntimeFailure: { _, _, _ in },
                onAudioLevel: { source, level in
                    levelRecorder.append(source: source, level: level)
                }
            )
            _ = try await controller.startPrepared()
            let pipeline = try #require(pipelineStore.pipelines(for: .microphone).first)
            let runtimeID = try #require(await controller.sourceRuntimes[.microphone]?.id)
            try pipeline.router.route(makeChunk(sample: 0.3, time: 0))
            try await levelRecorder.waitUntilCount(1)

            let unexpectedStop = Task {
                await controller.handleUnexpectedCaptureStop(
                    source: .microphone,
                    runtimeID: runtimeID,
                    sessionId: sessionID,
                    message: "capture stopped"
                )
            }
            try await recognitionFinishGate.waitUntilWaiting()
            try await levelRecorder.waitUntilCount(2)
            let entriesBeforeRecognitionFinished = await levelRecorder.entries

            #expect(entriesBeforeRecognitionFinished.last?.level == 0)
            await recognitionFinishGate.release()
            await unexpectedStop.value
            await controller.abort()
        }

        private func makeChunk(sample: Float, time: TimeInterval) throws -> CapturedAudioChunk {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
            buffer.frameLength = 128
            let samples = try #require(buffer.floatChannelData?[0])
            for frame in 0 ..< Int(buffer.frameLength) {
                samples[frame] = sample
            }
            return CapturedAudioChunk(
                source: .microphone,
                buffer: buffer,
                sessionRelativeStartTime: CMTime(seconds: time, preferredTimescale: 16000)
            )
        }
    }

    @MainActor
    private final class MeteringLevelRecorder {
        struct Entry {
            let source: RecordingAudioSource
            let level: Double
        }

        private(set) var entries: [Entry] = []

        func append(source: RecordingAudioSource, level: Double) {
            entries.append(.init(source: source, level: level))
        }

        func waitUntilCount(_ count: Int, timeout: Duration = testPollTimeout) async throws {
            guard await pollUntil(timeout: timeout, { entries.count >= count }) else {
                throw MeteringTestError.timedOutWaitingForLevel
            }
        }
    }

    private final class MeteringPipelineStore: Sendable {
        private let storage = OSAllocatedUnfairLock(initialState: [RecordingAudioSource: [AudioSourcePipeline]]())

        func append(_ pipeline: AudioSourcePipeline) {
            storage.withLock { $0[pipeline.source, default: []].append(pipeline) }
        }

        func pipelines(for source: RecordingAudioSource) -> [AudioSourcePipeline] {
            storage.withLock { $0[source] ?? [] }
        }
    }

    private struct MeteringCaptureFactory: AudioCaptureSessionFactory {
        let pipelineStore: MeteringPipelineStore

        func requestPermission(for _: RecordingAudioSource) async throws {}

        func makeSession(
            for pipeline: AudioSourcePipeline,
            onWarning _: @escaping AudioCaptureWarningHandler,
            onUnexpectedStop _: @escaping AudioCaptureUnexpectedStopHandler
        ) -> any AudioCaptureSession {
            pipelineStore.append(pipeline)
            return MeteringCaptureSession()
        }
    }

    private actor MeteringCaptureSession: AudioCaptureSession {
        func start() async throws {}
        func stop() async throws {}
    }

    private struct MeteringRecognitionFactory: ProgressiveRecognitionSessionFactory {
        let finishGate: MeteringRecognitionFinishGate?

        init(finishGate: MeteringRecognitionFinishGate? = nil) {
            self.finishGate = finishGate
        }

        func prepareModel(locale _: Locale) async throws {}

        func prepareSession(
            locale _: Locale,
            source _: RecordingAudioSource,
            sourceFormat _: AVAudioFormat?,
            bufferingMode _: AudioBufferBridge.BufferingMode,
            translateSegment _: ProgressiveSegmentTranslationHandler?
        ) async throws -> PreparedProgressiveRecognitionSession {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
            return PreparedProgressiveRecognitionSession(
                analyzerFormat: format,
                session: MeteringRecognitionSession(finishGate: finishGate)
            )
        }
    }

    private actor MeteringRecognitionSession: ProgressiveRecognitionSession {
        nonisolated let pipelineID = UUID.v7()
        nonisolated let liveConsumer: AudioFrameRouter.LiveConsumer = { _ in true }
        private let finishGate: MeteringRecognitionFinishGate?

        init(finishGate: MeteringRecognitionFinishGate?) {
            self.finishGate = finishGate
        }

        func start(
            recordingStartTime _: Date,
            recordingSessionId _: UUID,
            onEvent _: @escaping ProgressiveTranscriptionEventHandler
        ) async throws {}

        func finish() async throws {
            await finishGate?.wait()
        }

        func cancel() async {}
    }

    private actor MeteringRecognitionFinishGate {
        private var isWaiting = false
        private var isReleased = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            isWaiting = true
            guard !isReleased else { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func waitUntilWaiting(timeout: Duration = testPollTimeout) async throws {
            guard await pollUntil(timeout: timeout, { isWaiting }) else {
                throw MeteringTestError.timedOutWaitingForRecognitionFinish
            }
        }

        func release() {
            isReleased = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    private struct UnusedMeteringBatchFactory: BatchRecordingSessionFactory {
        func makeSession(
            dbQueue _: DatabaseQueue,
            managedRootURL _: URL,
            meetingId _: UUID,
            recordingSessionId _: UUID,
            recordingStartTime _: Date,
            sampleRate _: Double
        ) throws -> any BatchRecordingSession {
            throw MeteringTestError.unexpectedBatchRecording
        }
    }

    private enum MeteringTestError: Error {
        case unexpectedBatchRecording
        case timedOutWaitingForLevel
        case timedOutWaitingForRecognitionFinish
    }
#endif
