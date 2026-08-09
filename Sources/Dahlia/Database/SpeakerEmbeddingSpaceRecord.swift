import Foundation
import GRDB

struct SpeakerEmbeddingSpaceRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    static let databaseTableName = "speaker_embedding_spaces"

    var id: UUID
    var provider: String
    var modelName: String
    var revision: String
    var assetFingerprint: String
    var fluidAudioVersion: String
    var dimensionCount: Int
    var sampleRate: Int
    var preprocessing: String
    var excludesOverlap: Bool
    var normalization: String
    var similarityDefinition: String
    var createdAt: Date

    var space: SpeakerEmbeddingSpace {
        SpeakerEmbeddingSpace(
            provider: provider,
            modelName: modelName,
            revision: revision,
            assetFingerprint: assetFingerprint,
            fluidAudioVersion: fluidAudioVersion,
            dimensionCount: dimensionCount,
            sampleRate: sampleRate,
            preprocessing: preprocessing,
            excludesOverlap: excludesOverlap,
            normalization: normalization,
            similarityDefinition: similarityDefinition
        )
    }

    init(id: UUID, space: SpeakerEmbeddingSpace, createdAt: Date) {
        self.id = id
        provider = space.provider
        modelName = space.modelName
        revision = space.revision
        assetFingerprint = space.assetFingerprint
        fluidAudioVersion = space.fluidAudioVersion
        dimensionCount = space.dimensionCount
        sampleRate = space.sampleRate
        preprocessing = space.preprocessing
        excludesOverlap = space.excludesOverlap
        normalization = space.normalization
        similarityDefinition = space.similarityDefinition
        self.createdAt = createdAt
    }
}
