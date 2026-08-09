import Foundation
import Synchronization

struct SpeakerProfileCacheKey: Hashable, Sendable {
    let vaultId: UUID
    let embeddingSpaceId: UUID
}

struct CachedSpeakerProfile: Equatable, Sendable {
    let contactId: UUID
    let embedding: SpeakerEmbedding
}

actor SpeakerProfileCache {
    typealias Loader = @Sendable () async throws -> [CachedSpeakerProfile]

    private struct Entry {
        let generation: UInt64
        let profiles: [CachedSpeakerProfile]
    }

    private var profilesByKey: [SpeakerProfileCacheKey: Entry] = [:]
    private nonisolated let generations = Mutex<[SpeakerProfileCacheKey: UInt64]>([:])

    func profiles(for key: SpeakerProfileCacheKey, loader: Loader) async throws -> [CachedSpeakerProfile] {
        let currentGeneration = generation(for: key)
        if let entry = profilesByKey[key], entry.generation == currentGeneration {
            return entry.profiles
        }

        while true {
            let requestedGeneration = generation(for: key)
            let loaded = try await loader()
            let latestGeneration = generation(for: key)
            guard latestGeneration == requestedGeneration else {
                if let entry = profilesByKey[key], entry.generation == latestGeneration {
                    return entry.profiles
                }
                continue
            }
            profilesByKey[key] = Entry(generation: requestedGeneration, profiles: loaded)
            return loaded
        }
    }

    func invalidate(_ keys: Set<SpeakerProfileCacheKey>) {
        invalidateAfterCommit(keys)
    }

    func removeAll() {
        invalidateAllAfterCommit()
    }

    func invalidate(vaultId: UUID) {
        invalidateVaultAfterCommit(vaultId)
    }

    nonisolated func invalidateAfterCommit(_ keys: Set<SpeakerProfileCacheKey>) {
        generations.withLock { generations in
            for key in keys {
                generations[key, default: 0] &+= 1
            }
        }
    }

    nonisolated func invalidateVaultAfterCommit(_ vaultId: UUID) {
        generations.withLock { generations in
            let keys = generations.keys.filter { $0.vaultId == vaultId }
            for key in keys {
                generations[key, default: 0] &+= 1
            }
        }
    }

    private nonisolated func invalidateAllAfterCommit() {
        generations.withLock { generations in
            for key in Array(generations.keys) {
                generations[key, default: 0] &+= 1
            }
        }
    }

    private nonisolated func generation(for key: SpeakerProfileCacheKey) -> UInt64 {
        generations.withLock { generations in
            if let generation = generations[key] {
                return generation
            }
            generations[key] = 0
            return 0
        }
    }
}
