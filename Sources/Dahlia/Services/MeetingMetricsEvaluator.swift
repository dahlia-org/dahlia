enum MeetingMetricsEvaluator {
    static func evaluate(_ result: MeetingMetricsResult) -> MeetingMetricsInsightSet {
        let totalTurnCount = (result.source(.microphone)?.turnCount ?? 0)
            + (result.source(.system)?.turnCount ?? 0)
        guard result.validSegmentCount > 0,
              result.conversationTalkSeconds >= MeetingMetricsConstants.minimumConversationTalkSeconds,
              totalTurnCount >= MeetingMetricsConstants.minimumTotalTurnCount else {
            return MeetingMetricsInsightSet(availability: .insufficientTranscript, findings: [])
        }
        guard result.labelledSegmentRatio >= MeetingMetricsConstants.minimumLabelledSegmentRatio,
              result.unknownCharacterRatio <= MeetingMetricsConstants.maximumUnknownCharacterRatio,
              result.validCharacterRatio >= MeetingMetricsConstants.minimumValidCharacterRatio else {
            return MeetingMetricsInsightSet(availability: .insufficientCoverage, findings: [])
        }

        var findings: [MeetingMetricsFinding] = []
        if let microphone = result.source(.microphone),
           microphone.speakingSeconds >= MeetingMetricsConstants.micPaceMinimumSpeakingSeconds,
           microphone.turnCount >= MeetingMetricsConstants.micPaceMinimumTurnCount,
           microphone.cjkRatio >= MeetingMetricsConstants.minimumCJKCharacterRatio,
           let pace = microphone.charactersPerMinute,
           pace >= MeetingMetricsConstants.provisionalFastCharactersPerMinute {
            findings.append(MeetingMetricsFinding(kind: .micPaceProvisionalFast, evidence: .charactersPerMinute(pace)))
        }
        if result.sourceComparisonGatePassed,
           let balance = result.talkBalance,
           balance >= MeetingMetricsConstants.highMicShareThreshold {
            findings.append(MeetingMetricsFinding(kind: .highMicShare, evidence: .share(balance)))
        }
        if result.sourceComparisonGatePassed,
           let overlapSeconds = result.overlapSeconds,
           result.conversationTalkSeconds > 0 {
            let share = min(1, overlapSeconds / result.conversationTalkSeconds)
            if share >= MeetingMetricsConstants.highOverlapShareThreshold {
                findings.append(MeetingMetricsFinding(
                    kind: .highSourceOverlap,
                    evidence: .overlap(seconds: overlapSeconds, share: share)
                ))
            }
        }
        findings.sort {
            guard let left = MeetingMetricsFinding.Kind.allCases.firstIndex(of: $0.kind),
                  let right = MeetingMetricsFinding.Kind.allCases.firstIndex(of: $1.kind) else { return false }
            return left < right
        }
        return MeetingMetricsInsightSet(availability: .ok, findings: findings)
    }
}
