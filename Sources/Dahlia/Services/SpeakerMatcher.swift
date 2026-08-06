import Accelerate
import Foundation

enum SpeakerMatcher {
    static func rank(
        embedding: SpeakerEmbedding,
        profiles: [CachedSpeakerProfile],
        policy: SpeakerMatchPolicy
    ) -> SpeakerMatchRanking {
        guard embedding.values.count == embedding.space.dimensionCount,
              SpeakerEmbeddingValidation.normalizedChunk(embedding.values) != nil
        else {
            return undeterminable(.invalidEmbedding)
        }

        let scores = profiles.compactMap { profile -> (UUID, Float)? in
            guard profile.embedding.space == embedding.space,
                  profile.embedding.values.count == embedding.values.count
            else {
                return nil
            }
            return (profile.contactId, vDSP.dot(embedding.values, profile.embedding.values))
        }.filter(\.1.isFinite)
            .sorted {
                if $0.1 == $1.1 { return $0.0.uuidString < $1.0.uuidString }
                return $0.1 > $1.1
            }

        guard let top1 = scores.first else {
            let reason: SpeakerMatchUnknownReason = profiles.isEmpty ? .insufficientEvidence : .incompatibleEmbeddingSpace
            return undeterminable(reason)
        }
        let top2 = scores.dropFirst().first
        let margin = top2.map { top1.1 - $0.1 }

        if policy.state == .calibrationRequired {
            return SpeakerMatchRanking(
                top1ContactId: top1.0,
                top1Score: top1.1,
                top2ContactId: top2?.0,
                top2Score: top2?.1,
                margin: margin,
                state: .referenceOnly,
                unknownReason: nil
            )
        }

        guard let minimumSimilarity = policy.minimumSimilarity,
              let minimumMargin = policy.minimumMargin,
              top1.1 >= minimumSimilarity
        else {
            return ranking(top1: top1, top2: top2, margin: margin, reason: .belowThreshold)
        }
        guard let margin, margin >= minimumMargin else {
            return ranking(top1: top1, top2: top2, margin: margin, reason: .insufficientEvidence)
        }
        return SpeakerMatchRanking(
            top1ContactId: top1.0,
            top1Score: top1.1,
            top2ContactId: top2?.0,
            top2Score: top2?.1,
            margin: margin,
            state: .suggested,
            unknownReason: nil
        )
    }

    private static func undeterminable(_ reason: SpeakerMatchUnknownReason) -> SpeakerMatchRanking {
        SpeakerMatchRanking(
            top1ContactId: nil,
            top1Score: nil,
            top2ContactId: nil,
            top2Score: nil,
            margin: nil,
            state: .undeterminable,
            unknownReason: reason
        )
    }

    private static func ranking(
        top1: (UUID, Float),
        top2: (UUID, Float)?,
        margin: Float?,
        reason: SpeakerMatchUnknownReason
    ) -> SpeakerMatchRanking {
        SpeakerMatchRanking(
            top1ContactId: top1.0,
            top1Score: top1.1,
            top2ContactId: top2?.0,
            top2Score: top2?.1,
            margin: margin,
            state: .undeterminable,
            unknownReason: reason
        )
    }
}
