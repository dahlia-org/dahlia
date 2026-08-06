import Foundation

protocol SpeakerEmbeddingExtractor: Sendable {
    func extract(from source: MemoryMappedAudioSampleSource) async throws -> [MeetingSpeakerEvidence]
}

struct SpeakerEmbeddingQualityPolicy: Equatable, Sendable {
    /// These thresholds decide what Dahlia may persist. They are independent of
    /// FluidAudio's segment reconstruction and embedding configuration.
    static let production = Self(
        minimumSegmentDurationSeconds: 1.0,
        minimumRMS: 0.01,
        maximumClippingRatio: 0.01,
        minimumSegmentQuality: 0.5
    )

    let minimumSegmentDurationSeconds: Double
    let minimumRMS: Float
    let maximumClippingRatio: Float
    let minimumSegmentQuality: Float

    func accepts(_ chunk: SpeakerEmbeddingChunk) -> Bool {
        chunk.durationSeconds >= minimumSegmentDurationSeconds
            && chunk.rms >= minimumRMS
            && chunk.clippingRatio <= maximumClippingRatio
            && chunk.segmentQuality >= minimumSegmentQuality
    }

    func weight(for chunk: SpeakerEmbeddingChunk) -> Float {
        Float(chunk.durationSeconds) * chunk.rms * chunk.segmentQuality * (1 - chunk.clippingRatio)
    }
}

struct SpeakerEmbeddingChunk: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let speakerID: String
    let startTimeSeconds: Double
    let endTimeSeconds: Double
    let durationSeconds: Double
    let embedding: [Float]
    let rms: Float
    let clippingRatio: Float
    let segmentQuality: Float

    var description: String {
        "SpeakerEmbeddingChunk(speakerID: \(speakerID), duration: \(durationSeconds), embedding: <redacted>)"
    }

    var debugDescription: String { description }
}

struct SpeakerDiarizationOutput: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let chunks: [SpeakerEmbeddingChunk]
    let speakerDatabase: [String: [Float]]

    var description: String {
        "SpeakerDiarizationOutput(chunks: \(chunks.count), speakers: \(speakerDatabase.count), embeddings: <redacted>)"
    }

    var debugDescription: String { description }
}

protocol SpeakerDiarizationProcessing: Sendable {
    func process(source: MemoryMappedAudioSampleSource) async throws -> SpeakerDiarizationOutput
}

enum SpeakerEmbeddingValidation {
    static let dimensionCount = 256
    static let unitNormTolerance: Float = 0.05

    static func normalizedChunk(_ values: [Float]) -> [Float]? {
        guard values.count == dimensionCount,
              values.allSatisfy(\.isFinite) else { return nil }
        let norm = l2Norm(values)
        guard norm.isFinite,
              abs(norm - 1) <= unitNormTolerance else { return nil }
        return normalize(values, norm: norm)
    }

    static func normalizedSpeakerDatabaseValue(_ values: [Float]) -> [Float]? {
        guard values.count == dimensionCount,
              values.allSatisfy(\.isFinite) else { return nil }
        let norm = l2Norm(values)
        guard norm.isFinite, norm > 0 else { return nil }
        return normalize(values, norm: norm)
    }

    static func normalizedMean(_ weightedValues: [([Float], Float)]) -> [Float]? {
        guard !weightedValues.isEmpty else { return nil }
        var mean = [Float](repeating: 0, count: dimensionCount)
        for (values, weight) in weightedValues {
            for index in mean.indices {
                mean[index] += values[index] * weight
            }
        }
        let norm = l2Norm(mean)
        guard norm.isFinite, norm > 0 else { return nil }
        return normalize(mean, norm: norm)
    }

    static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> SpeakerMatchResult {
        guard lhs.count == dimensionCount, rhs.count == dimensionCount else {
            return .unknown(.invalidEmbedding)
        }
        let score = zip(lhs, rhs).reduce(Float.zero) { $0 + $1.0 * $1.1 }
        return score.isFinite ? .candidate(score: score) : .unknown(.invalidEmbedding)
    }

    private static func l2Norm(_ values: [Float]) -> Float {
        sqrt(values.reduce(Float.zero) { $0 + $1 * $1 })
    }

    private static func normalize(_ values: [Float], norm: Float) -> [Float] {
        values.map { $0 / norm }
    }
}

enum MeetingSpeakerEvidenceBuilder {
    private static let maximumExemplarCount = 3
    /// This compares a weighted mean of accepted chunk embeddings with FluidAudio's
    /// mean of cluster centroids. If it rejects a speaker, learning is disabled with
    /// no user-visible signal. Keep 0.8 as a Phase 6 Japanese-real-data calibration target.
    private static let minimumDatabaseConsistency: Float = 0.8

    static func build(
        output: SpeakerDiarizationOutput,
        space: SpeakerEmbeddingSpace,
        qualityPolicy: SpeakerEmbeddingQualityPolicy
    ) -> [MeetingSpeakerEvidence] {
        let database = output.speakerDatabase.compactMapValues {
            SpeakerEmbeddingValidation.normalizedSpeakerDatabaseValue($0)
        }
        let speakerIDs = Set(output.chunks.map(\.speakerID)).union(database.keys)

        return speakerIDs.sorted().compactMap { speakerID in
            let validChunks = output.chunks
                .filter { $0.speakerID == speakerID && qualityPolicy.accepts($0) }
                .compactMap { chunk -> (chunk: SpeakerEmbeddingChunk, embedding: [Float], weight: Float)? in
                    guard let embedding = SpeakerEmbeddingValidation.normalizedChunk(chunk.embedding) else { return nil }
                    return (chunk, embedding, qualityPolicy.weight(for: chunk))
                }

            guard let representative = SpeakerEmbeddingValidation.normalizedMean(
                validChunks.map { ($0.embedding, $0.weight) }
            ) else {
                guard let fallback = database[speakerID] else { return nil }
                return MeetingSpeakerEvidence(
                    speakerID: speakerID,
                    representative: SpeakerEmbedding(space: space, values: fallback),
                    exemplars: [],
                    profileUpdateEligible: false
                )
            }

            if let fluidRepresentative = database[speakerID],
               similarityScore(representative, fluidRepresentative) < minimumDatabaseConsistency {
                return MeetingSpeakerEvidence(
                    speakerID: speakerID,
                    representative: SpeakerEmbedding(space: space, values: representative),
                    exemplars: [],
                    profileUpdateEligible: false
                )
            }

            let exemplars = validChunks
                .sorted { lhs, rhs in
                    let lhsSimilarity = similarityScore(lhs.embedding, representative)
                    let rhsSimilarity = similarityScore(rhs.embedding, representative)
                    if lhsSimilarity == rhsSimilarity {
                        return lhs.weight > rhs.weight
                    }
                    return lhsSimilarity > rhsSimilarity
                }
                .prefix(maximumExemplarCount)
                .map { SpeakerEmbedding(space: space, values: $0.embedding) }

            return MeetingSpeakerEvidence(
                speakerID: speakerID,
                representative: SpeakerEmbedding(space: space, values: representative),
                exemplars: exemplars,
                profileUpdateEligible: true
            )
        }
    }

    private static func similarityScore(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard case let .candidate(score) = SpeakerEmbeddingValidation.cosineSimilarity(lhs, rhs) else {
            return -.infinity
        }
        return score
    }
}
