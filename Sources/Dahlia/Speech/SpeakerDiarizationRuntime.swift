import FluidAudio
import Foundation

enum SpeakerDiarizationBootstrap {
    static func startProcess() {
        ModelHub.offlineMode = true
    }
}

actor SerialDiarizerHost {
    typealias LoadHook = @Sendable () async throws -> Void

    private struct Request {
        let source: MemoryMappedAudioSampleSource
        let continuation: CheckedContinuation<SpeakerDiarizationOutput, any Error>
    }

    private enum Backend: Sendable {
        case fluidAudio(assetManager: SpeakerModelAssetManager)
        case injected(processor: any SpeakerDiarizationProcessing, loadHook: LoadHook)
    }

    private let backend: Backend
    private let configuration: OfflineDiarizerConfig
    private var continuation: AsyncStream<Request>.Continuation?
    private var worker: Task<Void, Never>?

    init(
        assetManager: SpeakerModelAssetManager,
        configuration: OfflineDiarizerConfig
    ) {
        backend = .fluidAudio(assetManager: assetManager)
        self.configuration = configuration
    }

    init(
        processor: any SpeakerDiarizationProcessing,
        loadHook: @escaping LoadHook = {}
    ) {
        backend = .injected(processor: processor, loadHook: loadHook)
        configuration = OfflineDiarizerConfig()
    }

    func process(source: MemoryMappedAudioSampleSource) async throws -> SpeakerDiarizationOutput {
        startIfNeeded()
        guard let continuation else {
            throw SpeakerMatchUnknownReason.analysisFailed
        }
        return try await withCheckedThrowingContinuation { requestContinuation in
            continuation.yield(Request(source: source, continuation: requestContinuation))
        }
    }

    private func startIfNeeded() {
        guard worker == nil else { return }
        let (stream, continuation) = AsyncStream<Request>.makeStream()
        self.continuation = continuation
        let backend = backend
        let configuration = configuration
        worker = Task {
            switch backend {
            case let .fluidAudio(assetManager):
                await Self.runFluidAudioWorker(
                    assetManager: assetManager,
                    configuration: configuration,
                    stream: stream
                )
            case let .injected(processor, loadHook):
                await Self.runInjectedWorker(
                    processor: processor,
                    loadHook: loadHook,
                    stream: stream
                )
            }
        }
    }

    private static func runFluidAudioWorker(
        assetManager: SpeakerModelAssetManager,
        configuration: OfflineDiarizerConfig,
        stream: AsyncStream<Request>
    ) async {
        do {
            let models = try await FluidAudioSpeakerEmbeddingExtractor.loadVerifiedModels(from: assetManager)
            let manager = OfflineDiarizerManager(config: configuration)
            manager.initialize(models: models)
            for await request in stream {
                do {
                    let result = try await manager.process(
                        audioSource: request.source,
                        audioLoadingSeconds: 0
                    )
                    let output = try FluidAudioSpeakerEmbeddingExtractor.makeOutput(
                        from: result,
                        source: request.source
                    )
                    request.continuation.resume(returning: output)
                } catch {
                    request.continuation.resume(throwing: error)
                }
            }
        } catch {
            await failRequests(in: stream, error: error)
        }
    }

    private static func runInjectedWorker(
        processor: any SpeakerDiarizationProcessing,
        loadHook: LoadHook,
        stream: AsyncStream<Request>
    ) async {
        do {
            try await loadHook()
            for await request in stream {
                do {
                    let output = try await processor.process(source: request.source)
                    request.continuation.resume(returning: output)
                } catch {
                    request.continuation.resume(throwing: error)
                }
            }
        } catch {
            await failRequests(in: stream, error: error)
        }
    }

    private static func failRequests(
        in stream: AsyncStream<Request>,
        error: any Error
    ) async {
        for await request in stream {
            request.continuation.resume(throwing: error)
        }
    }
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
        let output = try await host.process(source: source)
        let space = if let injectedSpace {
            injectedSpace
        } else if let assetManager {
            await assetManager.embeddingSpace()
        } else {
            throw SpeakerMatchUnknownReason.analysisFailed
        }
        return MeetingSpeakerEvidenceBuilder.build(
            output: output,
            space: space,
            qualityPolicy: qualityPolicy
        )
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
            speakerDatabase: result.speakerDatabase ?? [:]
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
