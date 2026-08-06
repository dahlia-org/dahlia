import FluidAudio
import Foundation

enum SpeakerDiarizationBootstrap {
    static func startProcess() {
        ModelHub.offlineMode = true
    }
}

actor FluidAudioSpeakerEmbeddingExtractor: SpeakerEmbeddingExtractor {
    private let assetManager: SpeakerModelAssetManager?
    private let qualityPolicy: SpeakerEmbeddingQualityPolicy
    private let injectedProcessor: (any SpeakerDiarizationProcessing)?
    private let injectedSpace: SpeakerEmbeddingSpace?
    // FluidAudio's manager is not Sendable even though `process` is async.
    // The actor single-flight guard serializes its Core ML access; the
    // nonisolated helper exists only to bridge that API mismatch.
    private nonisolated(unsafe) var manager: OfflineDiarizerManager?
    private var isProcessing = false

    init(
        assetManager: SpeakerModelAssetManager,
        qualityPolicy: SpeakerEmbeddingQualityPolicy = .production
    ) {
        self.assetManager = assetManager
        self.qualityPolicy = qualityPolicy
        injectedProcessor = nil
        injectedSpace = nil
    }

    init(
        processor: any SpeakerDiarizationProcessing,
        space: SpeakerEmbeddingSpace,
        qualityPolicy: SpeakerEmbeddingQualityPolicy = .production
    ) {
        assetManager = nil
        self.qualityPolicy = qualityPolicy
        injectedProcessor = processor
        injectedSpace = space
    }

    func loadVerifiedModels() async throws {
        guard let assetManager else {
            throw SpeakerMatchUnknownReason.analysisFailed
        }
        let revisionRootURL = try await assetManager.verifiedRevisionRootURL()
        SpeakerDiarizationBootstrap.startProcess()

        let models = try await OfflineDiarizerModels.load(from: revisionRootURL)
        let manager = OfflineDiarizerManager(config: Self.diarizationConfiguration())
        manager.initialize(models: models)
        self.manager = manager
    }

    func extract(from source: MemoryMappedAudioSampleSource) async throws -> [MeetingSpeakerEvidence] {
        let output: SpeakerDiarizationOutput
        if let injectedProcessor {
            output = try await injectedProcessor.process(source: source)
        } else {
            if manager == nil {
                try await loadVerifiedModels()
            }
            guard !isProcessing else {
                throw SpeakerMatchUnknownReason.analysisFailed
            }
            isProcessing = true
            defer { isProcessing = false }
            let result = try await processWithFluidAudio(source: source)
            output = try Self.makeOutput(from: result, source: source)
        }

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
        return configuration
    }

    private nonisolated func processWithFluidAudio(
        source: MemoryMappedAudioSampleSource
    ) async throws -> DiarizationResult {
        guard let manager else {
            throw SpeakerMatchUnknownReason.analysisFailed
        }
        return try await manager.process(
            audioSource: source,
            audioLoadingSeconds: 0
        )
    }

    private static func makeOutput(
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
