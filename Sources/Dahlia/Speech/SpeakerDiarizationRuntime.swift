import FluidAudio
import Foundation
import os

enum SpeakerDiarizationBootstrap {
    static func startProcess() {
        ModelHub.offlineMode = true
    }
}

final class SerialDiarizerHost: Sendable {
    typealias LoadHook = @Sendable () async throws -> Void
    typealias ProcessingTaskFactory = @Sendable (
        @escaping @Sendable () async throws -> SpeakerDiarizationOutput
    ) -> Task<SpeakerDiarizationOutput, any Error>

    struct Request {
        let source: MemoryMappedAudioSampleSource
        let ticket: RequestTicket
    }

    private enum Backend: Sendable {
        case fluidAudio(assetManager: SpeakerModelAssetManager)
        case injected(processor: any SpeakerDiarizationProcessing, loadHook: LoadHook)
    }

    private let lifecycle: Lifecycle

    init(
        assetManager: SpeakerModelAssetManager,
        configuration: OfflineDiarizerConfig
    ) {
        lifecycle = Lifecycle(
            backend: .fluidAudio(assetManager: assetManager),
            configuration: configuration
        )
    }

    init(
        processor: any SpeakerDiarizationProcessing,
        loadHook: @escaping LoadHook = {}
    ) {
        lifecycle = Lifecycle(
            backend: .injected(processor: processor, loadHook: loadHook),
            configuration: OfflineDiarizerConfig()
        )
    }

    func process(source: MemoryMappedAudioSampleSource) async throws -> SpeakerDiarizationOutput {
        try Task.checkCancellation()
        let ticket = RequestTicket()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { requestContinuation in
                ticket.install(continuation: requestContinuation)
                lifecycle.enqueue(Request(source: source, ticket: ticket))
            }
        } onCancel: {
            ticket.cancel()
        }
    }

    func shutdown() async {
        await lifecycle.shutdown()
    }

    deinit {
        lifecycle.shutdownSynchronously()
    }

    private final class Lifecycle: Sendable {
        private enum Phase: Sendable {
            case idle
            case loading(generation: UInt64)
            case ready(generation: UInt64)
            case shutDown
        }

        private struct State {
            var phase = Phase.idle
            var nextGeneration: UInt64 = 0
            var requests: [Request] = []
            var requestWaiter: CheckedContinuation<Request?, Never>?
            var worker: Task<Void, Never>?
        }

        private enum EnqueueAction {
            case none
            case resume(CheckedContinuation<Request?, Never>)
            case reject
        }

        private enum NextRequestAction {
            case resume(Request?)
            case wait
        }

        private let backend: Backend
        private let configuration: OfflineDiarizerConfig
        private let state = OSAllocatedUnfairLock(initialState: State())

        init(backend: Backend, configuration: OfflineDiarizerConfig) {
            self.backend = backend
            self.configuration = configuration
        }

        // Lifecycle invariants, all enforced by the single `state` lock:
        // I1: `.loading` and `.ready` each own exactly one worker generation; only that worker loads and processes.
        // I2: every request observed during `.loading` joins that generation instead of starting another load.
        // I3: a load failure atomically fails that generation's requests and moves to `.idle` for a later retry.
        // I4: every non-idle path retains its worker until failure or shutdown; shutdown cancels and awaits it.
        // I5: request cancellation cancels only the active request's child task, never the worker.
        // I6: `.shutDown` is terminal and rejects every subsequent request without creating a worker.
        func enqueue(_ request: Request) {
            let action = state.withLock { state -> EnqueueAction in
                guard !request.ticket.isCompleted else { return .none }
                switch state.phase {
                case .shutDown:
                    return .reject
                case .idle:
                    state.requests.append(request)
                    state.nextGeneration += 1
                    let generation = state.nextGeneration
                    state.phase = .loading(generation: generation)
                    state.worker = Task { [self] in
                        await run(generation: generation)
                    }
                    return .none
                case .loading:
                    state.requests.append(request)
                    return .none
                case .ready:
                    if let requestWaiter = state.requestWaiter {
                        state.requestWaiter = nil
                        return .resume(requestWaiter)
                    } else {
                        state.requests.append(request)
                        return .none
                    }
                }
            }
            switch action {
            case .none:
                break
            case let .resume(waiter):
                waiter.resume(returning: request)
            case .reject:
                request.ticket.complete(.failure(SerialDiarizerHostError.shutDown))
            }
        }

        func shutdown() async {
            let worker = beginShutdown()
            await worker?.value
            state.withLock { $0.worker = nil }
        }

        func shutdownSynchronously() {
            _ = beginShutdown()
        }

        private func beginShutdown() -> Task<Void, Never>? {
            let resources = state.withLock { state -> (
                Task<Void, Never>?,
                [Request],
                CheckedContinuation<Request?, Never>?
            ) in
                guard case .shutDown = state.phase else {
                    state.phase = .shutDown
                    let requests = state.requests
                    state.requests.removeAll()
                    let waiter = state.requestWaiter
                    state.requestWaiter = nil
                    return (state.worker, requests, waiter)
                }
                return (state.worker, [], nil)
            }
            resources.1.forEach { $0.ticket.complete(.failure(CancellationError())) }
            resources.2?.resume(returning: nil)
            resources.0?.cancel()
            return resources.0
        }

        private func run(generation: UInt64) async {
            switch backend {
            case let .fluidAudio(assetManager):
                do {
                    let models = try await FluidAudioSpeakerEmbeddingExtractor.loadVerifiedModels(from: assetManager)
                    let processor = FluidAudioProcessor(models: models, configuration: configuration)
                    guard loadingDidSucceed(generation: generation) else { return }
                    await processRequests(generation: generation) { request in
                        try await processor.process(request: request)
                    }
                } catch {
                    loadingDidFail(generation: generation, error: error)
                }
            case let .injected(processor, loadHook):
                do {
                    try await loadHook()
                    guard loadingDidSucceed(generation: generation) else { return }
                    await processRequests(generation: generation) { request in
                        try await processor.process(source: request.source)
                    }
                } catch {
                    loadingDidFail(generation: generation, error: error)
                }
            }
        }

        private func loadingDidSucceed(generation: UInt64) -> Bool {
            state.withLock { state in
                guard case .loading(generation) = state.phase else { return false }
                state.phase = .ready(generation: generation)
                return true
            }
        }

        private func loadingDidFail(generation: UInt64, error: any Error) {
            let requests = state.withLock { state -> [Request] in
                guard case .loading(generation) = state.phase else { return [] }
                state.phase = .idle
                state.worker = nil
                let requests = state.requests
                state.requests.removeAll()
                return requests
            }
            requests.forEach { $0.ticket.complete(.failure(error)) }
        }

        private func processRequests(
            generation: UInt64,
            operation: @escaping @Sendable (Request) async throws -> SpeakerDiarizationOutput
        ) async {
            while !Task.isCancelled, let request = await nextRequest(generation: generation) {
                guard !request.ticket.isCompleted else { continue }
                guard let result = await SerialDiarizerHost.processRequest(request, operation: operation) else { continue }
                request.ticket.complete(result)
            }
        }

        private func nextRequest(generation: UInt64) async -> Request? {
            await withCheckedContinuation { continuation in
                let action = state.withLock { state -> NextRequestAction in
                    guard case .ready(generation) = state.phase else { return .resume(nil) }
                    while let candidate = state.requests.first {
                        state.requests.removeFirst()
                        if !candidate.ticket.isCompleted {
                            return .resume(candidate)
                        }
                    }
                    state.requestWaiter = continuation
                    return .wait
                }
                if case let .resume(request) = action {
                    continuation.resume(returning: request)
                }
            }
        }

        /// FluidAudio's manager predates strict Sendable annotations. The lifecycle worker is its sole
        /// owner: every child request it starts is awaited to completion before the next starts, and the
        /// non-starting path creates no work. This prevents concurrent access across cancellation boundaries.
        private final class FluidAudioProcessor: @unchecked Sendable {
            private let manager: OfflineDiarizerManager

            init(models: OfflineDiarizerModels, configuration: OfflineDiarizerConfig) {
                manager = OfflineDiarizerManager(config: configuration)
                manager.initialize(models: models)
            }

            func process(request: Request) async throws -> SpeakerDiarizationOutput {
                let result = try await manager.process(audioSource: request.source, audioLoadingSeconds: 0)
                return try FluidAudioSpeakerEmbeddingExtractor.makeOutput(from: result, source: request.source)
            }
        }
    }
}

enum SerialDiarizerHostError: Error, Equatable {
    case shutDown
}

actor FluidAudioSpeakerEmbeddingExtractor: SpeakerEmbeddingExtractor {
    private let assetManager: SpeakerModelAssetManager?
    private let qualityPolicy: SpeakerEmbeddingQualityPolicy
    private let host: SerialDiarizerHost
    private let injectedSpace: SpeakerEmbeddingSpace?

    init(
        assetManager: SpeakerModelAssetManager,
        qualityPolicy: SpeakerEmbeddingQualityPolicy = .production
    ) {
        self.assetManager = assetManager
        self.qualityPolicy = qualityPolicy
        host = SerialDiarizerHost(
            assetManager: assetManager,
            configuration: Self.diarizationConfiguration()
        )
        injectedSpace = nil
    }

    init(
        processor: any SpeakerDiarizationProcessing,
        space: SpeakerEmbeddingSpace,
        qualityPolicy: SpeakerEmbeddingQualityPolicy = .production,
        loadHook: @escaping SerialDiarizerHost.LoadHook = {}
    ) {
        assetManager = nil
        self.qualityPolicy = qualityPolicy
        host = SerialDiarizerHost(processor: processor, loadHook: loadHook)
        injectedSpace = space
    }

    static func loadVerifiedModels(from assetManager: SpeakerModelAssetManager) async throws -> OfflineDiarizerModels {
        let revisionRootURL = try await assetManager.verifiedRevisionRootURL()
        return try await OfflineDiarizerModels.load(from: revisionRootURL)
    }

    func extract(from source: MemoryMappedAudioSampleSource) async throws -> [MeetingSpeakerEvidence] {
        try await analyze(from: source).speakers
    }

    func analyze(from source: MemoryMappedAudioSampleSource) async throws -> SpeakerAnalysisExtraction {
        let output = try await host.process(source: source)
        let space = if let injectedSpace {
            injectedSpace
        } else if let assetManager {
            await assetManager.embeddingSpace()
        } else {
            throw SpeakerMatchUnknownReason.analysisFailed
        }
        return SpeakerAnalysisExtraction(
            embeddingSpace: space,
            speakers: MeetingSpeakerEvidenceBuilder.build(
                output: output,
                space: space,
                qualityPolicy: qualityPolicy
            ),
            spans: output.spans
        )
    }

    func shutdown() async {
        await host.shutdown()
    }

    static func diarizationConfiguration() -> OfflineDiarizerConfig {
        // FluidAudio 0.15.5 has no top-level `.community` preset. Its initializer
        // composes the Community defaults for every pipeline stage.
        var configuration = OfflineDiarizerConfig()
        configuration.embedding.excludeOverlap = true
        configuration.exposeChunkEmbeddings = true
        // Community post-processing uses exclusive segments. FluidAudio scales a
        // segment's quality by retained/original duration while trimming overlap,
        // so retaining under 50% fails Dahlia's 0.5 gate regardless of acoustics.
        // Keep this behavior visible as a Phase 6 Japanese-real-data calibration target.
        return configuration
    }

    static func makeOutput(
        from result: DiarizationResult,
        source: MemoryMappedAudioSampleSource
    ) throws -> SpeakerDiarizationOutput {
        let chunks = try (result.chunkEmbeddings ?? []).compactMap { chunk -> SpeakerEmbeddingChunk? in
            let intersections = result.segments.compactMap { segment -> SpeakerSegmentIntersection? in
                guard segment.speakerId == chunk.speakerId else { return nil }
                let start = max(Double(segment.startTimeSeconds), chunk.startTimeSeconds)
                let end = min(Double(segment.endTimeSeconds), chunk.endTimeSeconds)
                guard end > start else { return nil }
                return SpeakerSegmentIntersection(
                    startTimeSeconds: start,
                    endTimeSeconds: end,
                    quality: segment.qualityScore
                )
            }
            guard !intersections.isEmpty else { return nil }
            let audioQuality = try measureAudioQuality(source: source, intersections: intersections)
            return SpeakerEmbeddingChunk(
                speakerID: chunk.speakerId,
                startTimeSeconds: chunk.startTimeSeconds,
                endTimeSeconds: chunk.endTimeSeconds,
                durationSeconds: intersections.reduce(0) { $0 + $1.durationSeconds },
                embedding: chunk.embedding256,
                rms: audioQuality.rms,
                clippingRatio: audioQuality.clippingRatio,
                segmentQuality: audioQuality.segmentQuality
            )
        }
        return SpeakerDiarizationOutput(
            chunks: chunks,
            speakerDatabase: result.speakerDatabase ?? [:],
            spans: result.segments.map {
                SpeakerDiarizationSpan(
                    speakerID: $0.speakerId,
                    startTimeSeconds: Double($0.startTimeSeconds),
                    endTimeSeconds: Double($0.endTimeSeconds)
                )
            }
        )
    }

    private static func measureAudioQuality(
        source: MemoryMappedAudioSampleSource,
        intersections: [SpeakerSegmentIntersection]
    ) throws -> (rms: Float, clippingRatio: Float, segmentQuality: Float) {
        var squaredSum: Double = 0
        var clippedSampleCount = 0
        var sampleCount = 0
        var weightedSegmentQuality: Double = 0
        var totalDuration: Double = 0

        for intersection in intersections {
            let offset = max(0, Int((intersection.startTimeSeconds * Double(source.sampleRate)).rounded()))
            let count = min(
                source.sampleCount - offset,
                Int((intersection.durationSeconds * Double(source.sampleRate)).rounded())
            )
            guard count > 0 else { continue }
            var samples = [Float](repeating: 0, count: count)
            try samples.withUnsafeMutableBufferPointer { pointer in
                guard let baseAddress = pointer.baseAddress else { return }
                try source.copySamples(into: baseAddress, offset: offset, count: count)
            }
            for sample in samples {
                squaredSum += Double(sample * sample)
                if abs(sample) >= 0.999 {
                    clippedSampleCount += 1
                }
            }
            sampleCount += count
            weightedSegmentQuality += Double(intersection.quality) * intersection.durationSeconds
            totalDuration += intersection.durationSeconds
        }

        guard sampleCount > 0, totalDuration > 0 else { return (0, 0, 0) }
        return (
            rms: Float(sqrt(squaredSum / Double(sampleCount))),
            clippingRatio: Float(clippedSampleCount) / Float(sampleCount),
            segmentQuality: Float(weightedSegmentQuality / totalDuration)
        )
    }
}

typealias SpeakerDiarizationRuntime = FluidAudioSpeakerEmbeddingExtractor

private struct SpeakerSegmentIntersection {
    let startTimeSeconds: Double
    let endTimeSeconds: Double
    let quality: Float

    var durationSeconds: Double { endTimeSeconds - startTimeSeconds }
}

extension MemoryMappedAudioSampleSource: AudioSampleSource {}
