@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct MeetingMetricsEvaluatorTests {
        @Test
        func coverageGatesSuppressAllFindings() {
            let labelled = MeetingMetricsTestSupport.result(confirmedSegmentCount: 10, unknownSourceSegmentCount: 3)
            let unknownCharacters = MeetingMetricsTestSupport.result(
                totalCharacterCount: 1000,
                unknownSourceCharacterCount: 300
            )
            let invalidCharacters = MeetingMetricsTestSupport.result(
                totalCharacterCount: 1000,
                validCharacterCount: 500
            )
            #expect(MeetingMetricsEvaluator.evaluate(labelled).availability == .insufficientCoverage)
            #expect(MeetingMetricsEvaluator.evaluate(unknownCharacters).availability == .insufficientCoverage)
            #expect(MeetingMetricsEvaluator.evaluate(invalidCharacters).findings.isEmpty)
        }

        @Test
        func transcriptGateRunsBeforeCoverageGate() {
            let result = MeetingMetricsTestSupport.result(
                conversationTalkSeconds: 120,
                confirmedSegmentCount: 10,
                unknownSourceSegmentCount: 5
            )
            #expect(MeetingMetricsEvaluator.evaluate(result).availability == .insufficientTranscript)
        }

        @Test
        func thinSourceEvidenceSuppressesBalanceAndOverlap() {
            let microphone = MeetingMetricsTestSupport.source(.microphone, seconds: 2, characters: 50, cjk: 50, turns: 4)
            let system = MeetingMetricsTestSupport.source(.system, seconds: 1, characters: 25, cjk: 25, turns: 4)
            let result = MeetingMetricsTestSupport.result(
                conversationTalkSeconds: 303,
                overlapSeconds: nil,
                talkBalance: nil,
                microphone: microphone,
                system: system
            )
            let findings = MeetingMetricsEvaluator.evaluate(result).findings
            #expect(!findings.contains { $0.kind == .highMicShare })
            #expect(!findings.contains { $0.kind == .highSourceOverlap })
        }

        @Test
        func findingsRequireTheirSpecificEvidence() {
            let lowCJK = MeetingMetricsTestSupport.source(.microphone, seconds: 150, characters: 1250, cjk: 500, turns: 3)
            let lowCJKResult = MeetingMetricsTestSupport.result(microphone: lowCJK)
            #expect(!MeetingMetricsEvaluator.evaluate(lowCJKResult).findings.contains { $0.kind == .micPaceProvisionalFast })

            let fast = MeetingMetricsTestSupport.source(.microphone, seconds: 150, characters: 1250, cjk: 1200, turns: 3)
            let fastResult = MeetingMetricsTestSupport.result(microphone: fast)
            #expect(MeetingMetricsEvaluator.evaluate(fastResult).findings.contains { $0.kind == .micPaceProvisionalFast })

            let highShare = MeetingMetricsTestSupport.result(talkBalance: 0.7)
            #expect(MeetingMetricsEvaluator.evaluate(highShare).findings.contains { $0.kind == .highMicShare })

            let noOverlap = MeetingMetricsTestSupport.result(overlapSeconds: nil)
            #expect(!MeetingMetricsEvaluator.evaluate(noOverlap).findings.contains { $0.kind == .highSourceOverlap })
        }

        @Test
        func findingsAreStableAndRatiosStayBounded() {
            let fast = MeetingMetricsTestSupport.source(.microphone, seconds: 150, characters: 1250, cjk: 1200, turns: 4)
            let system = MeetingMetricsTestSupport.source(.system, seconds: 150, characters: 400, cjk: 400, turns: 4)
            let result = MeetingMetricsTestSupport.result(
                overlapSeconds: 60,
                talkBalance: 0.75,
                microphone: fast,
                system: system
            )
            let first = MeetingMetricsEvaluator.evaluate(result)
            let second = MeetingMetricsEvaluator.evaluate(result)
            #expect(first == second)
            #expect(first.findings.map(\.kind) == [.micPaceProvisionalFast, .highMicShare, .highSourceOverlap])
            for finding in first.findings {
                if case let .overlap(_, share) = finding.evidence {
                    #expect((0 ... 1).contains(share))
                }
            }
        }

        @Test
        func belowThresholdsProducesNoNotableState() {
            let result = MeetingMetricsTestSupport.result()
            let insights = MeetingMetricsEvaluator.evaluate(result)
            #expect(insights.availability == .ok)
            #expect(insights.findings.isEmpty)
        }
    }
#endif
