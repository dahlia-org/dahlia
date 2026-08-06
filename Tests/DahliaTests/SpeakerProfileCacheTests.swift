import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct SpeakerProfileCacheTests {
        @Test
        func cacheHitsUntilPostCommitInvalidation() async throws {
            let cache = SpeakerProfileCache()
            let key = SpeakerProfileCacheKey(vaultId: .v7(), embeddingSpaceId: .v7())
            let counter = LoadCounter()
            let profile = makeProfile(contactId: .v7())

            _ = try await cache.profiles(for: key) {
                await counter.increment()
                return [profile]
            }
            _ = try await cache.profiles(for: key) {
                await counter.increment()
                return []
            }
            #expect(await counter.value == 1)

            await cache.invalidate([key])
            let reloaded = try await cache.profiles(for: key) {
                await counter.increment()
                return [profile]
            }
            #expect(reloaded == [profile])
            #expect(await counter.value == 2)
        }

        @Test
        func staleInflightLoadCannotRollBackNewGeneration() async throws {
            let cache = SpeakerProfileCache()
            let key = SpeakerProfileCacheKey(vaultId: .v7(), embeddingSpaceId: .v7())
            let gate = LoadGate()
            let old = makeProfile(contactId: .v7())
            let new = makeProfile(contactId: .v7())

            let staleTask = Task {
                try await cache.profiles(for: key) {
                    await gate.wait()
                    return [old]
                }
            }
            await gate.waitUntilBlocked()
            await cache.invalidate([key])
            let current = try await cache.profiles(for: key) { [new] }
            await gate.open()

            #expect(current == [new])
            #expect(try await staleTask.value == [new])
            let cached = try await cache.profiles(for: key) { [old] }
            #expect(cached == [new])
        }

        private func makeProfile(contactId: UUID) -> CachedSpeakerProfile {
            let space = SpeakerEmbeddingSpace(
                provider: "FluidAudio",
                modelName: "speaker-diarization",
                revision: "revision",
                assetFingerprint: "fingerprint",
                fluidAudioVersion: "0.15.5",
                dimensionCount: SpeakerEmbeddingValidation.dimensionCount,
                sampleRate: 16000,
                preprocessing: "mono-float32",
                excludesOverlap: true,
                normalization: "l2",
                similarityDefinition: "cosine-dot-product"
            )
            var values = [Float](repeating: 0, count: SpeakerEmbeddingValidation.dimensionCount)
            values[0] = 1
            return CachedSpeakerProfile(contactId: contactId, embedding: SpeakerEmbedding(space: space, values: values))
        }
    }

    private actor LoadCounter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    private actor LoadGate {
        private var blocked = false
        private var blockObservers: [CheckedContinuation<Void, Never>] = []
        private var loadContinuations: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            blocked = true
            blockObservers.forEach { $0.resume() }
            blockObservers.removeAll()
            await withCheckedContinuation { loadContinuations.append($0) }
        }

        func waitUntilBlocked() async {
            if blocked { return }
            await withCheckedContinuation { blockObservers.append($0) }
        }

        func open() {
            loadContinuations.forEach { $0.resume() }
            loadContinuations.removeAll()
        }
    }
#endif
