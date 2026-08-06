import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct SpeakerMatcherTests {
        @Test
        func vDSPCosineRanksTopTwoAndKeepsCalibrationReferenceOnly() {
            let space = makeSpace(revision: "one")
            let query = normalized([0.8, 0.6])
            let first = UUID.v7()
            let second = UUID.v7()
            let ranking = SpeakerMatcher.rank(
                embedding: SpeakerEmbedding(space: space, values: query),
                profiles: [
                    CachedSpeakerProfile(contactId: second, embedding: SpeakerEmbedding(space: space, values: unitVector(1))),
                    CachedSpeakerProfile(contactId: first, embedding: SpeakerEmbedding(space: space, values: unitVector(0))),
                ],
                policy: .calibrationRequired
            )

            #expect(ranking.top1ContactId == first)
            #expect(abs((ranking.top1Score ?? 0) - 0.8) < 0.000_01)
            #expect(ranking.top2ContactId == second)
            #expect(abs((ranking.top2Score ?? 0) - 0.6) < 0.000_01)
            #expect(abs((ranking.margin ?? 0) - 0.2) < 0.000_01)
            #expect(ranking.state == .referenceOnly)
        }

        @Test
        func excludesEveryMismatchedEmbeddingSpace() {
            let querySpace = makeSpace(revision: "one")
            let otherSpace = makeSpace(revision: "two")
            let ranking = SpeakerMatcher.rank(
                embedding: SpeakerEmbedding(space: querySpace, values: unitVector(0)),
                profiles: [
                    CachedSpeakerProfile(
                        contactId: .v7(),
                        embedding: SpeakerEmbedding(space: otherSpace, values: unitVector(0))
                    ),
                ],
                policy: .calibrationRequired
            )

            #expect(ranking.state == .undeterminable)
            #expect(ranking.unknownReason == .incompatibleEmbeddingSpace)
            #expect(ranking.top1ContactId == nil)
        }

        private func makeSpace(revision: String) -> SpeakerEmbeddingSpace {
            SpeakerEmbeddingSpace(
                provider: "FluidAudio",
                modelName: "speaker-diarization",
                revision: revision,
                assetFingerprint: "fingerprint",
                fluidAudioVersion: "0.15.5",
                dimensionCount: SpeakerEmbeddingValidation.dimensionCount,
                sampleRate: 16000,
                preprocessing: "mono-float32",
                excludesOverlap: true,
                normalization: "l2",
                similarityDefinition: "cosine-dot-product"
            )
        }

        private func unitVector(_ index: Int) -> [Float] {
            var values = [Float](repeating: 0, count: SpeakerEmbeddingValidation.dimensionCount)
            values[index] = 1
            return values
        }

        private func normalized(_ prefix: [Float]) -> [Float] {
            prefix + [Float](repeating: 0, count: SpeakerEmbeddingValidation.dimensionCount - prefix.count)
        }
    }
#endif
