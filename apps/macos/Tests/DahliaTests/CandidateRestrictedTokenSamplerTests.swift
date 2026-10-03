import CoreML
import Foundation
import WhisperKit
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct CandidateRestrictedTokenSamplerTests {
        @Test
        func choosesHighestCandidateButKeepsGlobalLanguageProbability() async throws {
            let logits = try languageLogits([
                1: 5,
                2: 2,
                3: 1,
            ])
            let sampler = CandidateRestrictedTokenSampler(
                allowedLanguageTokenIDs: [2, 3],
                allLanguageTokenIDs: [1, 2, 3],
                endToken: 5
            )

            let result = await sampler.update(tokens: [0], logits: logits, logProbs: [0])
            let expectedProbability = exp(Float(2)) / (exp(Float(5)) + exp(Float(2)) + exp(Float(1)))

            #expect(result.tokens.last == 2)
            #expect(abs(exp(result.logProbs.last ?? 0) - expectedProbability) < 0.0001)
        }

        @Test
        func equalCandidateLogitsUseTokenIdentityRatherThanConfigurationOrder() async throws {
            let logits = try languageLogits([
                2: 1,
                3: 1,
            ])
            let sampler = CandidateRestrictedTokenSampler(
                allowedLanguageTokenIDs: [3, 2],
                allLanguageTokenIDs: [2, 3],
                endToken: 5
            )

            let result = await sampler.update(tokens: [0], logits: logits, logProbs: [0])

            #expect(result.tokens.last == 2)
        }

        private func languageLogits(_ values: [Int: Float]) throws -> MLMultiArray {
            let logits = try MLMultiArray(shape: [6], dataType: .float32)
            for index in 0 ..< logits.count {
                logits[index] = NSNumber(value: -Float.infinity)
            }
            for (index, value) in values {
                logits[index] = NSNumber(value: value)
            }
            return logits
        }
    }
#endif
