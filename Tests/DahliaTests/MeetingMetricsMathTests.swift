import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct MeetingMetricsMathTests {
        @Test
        func sourceUnionMergesOverlappingAndTouchingIntervals() {
            #expect(MeetingMetricsMath.speakingSeconds([
                MeetingMetricsTestSupport.interval(0, 10),
                MeetingMetricsTestSupport.interval(5, 15),
            ]) == 15)
            #expect(MeetingMetricsMath.mergedIntervals([
                MeetingMetricsTestSupport.interval(0, 10),
                MeetingMetricsTestSupport.interval(10, 20),
            ]).count == 1)
        }

        @Test
        func overlapAndBalanceBoundaries() {
            let adjacent = MeetingMetricsMath.overlapSeconds(
                microphone: [MeetingMetricsTestSupport.interval(0, 50)],
                system: [MeetingMetricsTestSupport.interval(50, 100)]
            )
            let partial = MeetingMetricsMath.overlapSeconds(
                microphone: [MeetingMetricsTestSupport.interval(0, 50)],
                system: [MeetingMetricsTestSupport.interval(40, 90)]
            )
            let complete = MeetingMetricsMath.overlapSeconds(
                microphone: [MeetingMetricsTestSupport.interval(0, 50)],
                system: [MeetingMetricsTestSupport.interval(0, 50)]
            )
            #expect(adjacent == 0)
            #expect(partial == 10)
            #expect(complete == 50)
            #expect(50.0 / (50.0 + 50.0) == 0.5)
        }

        @Test
        func sourceUnionPrecedesIntersection() {
            let overlap = MeetingMetricsMath.overlapSeconds(
                microphone: [
                    MeetingMetricsTestSupport.interval(0, 10),
                    MeetingMetricsTestSupport.interval(5, 15),
                ],
                system: [MeetingMetricsTestSupport.interval(7, 12)]
            )
            #expect(overlap == 5)
        }

        @Test
        func twoPointerIntersectionAndEpisodeMinimum() {
            let multiple = MeetingMetricsMath.overlapSeconds(
                microphone: [
                    MeetingMetricsTestSupport.interval(0, 5),
                    MeetingMetricsTestSupport.interval(10, 15),
                    MeetingMetricsTestSupport.interval(20, 25),
                ],
                system: [
                    MeetingMetricsTestSupport.interval(3, 12),
                    MeetingMetricsTestSupport.interval(22, 30),
                ]
            )
            let exact = MeetingMetricsMath.overlapSeconds(
                microphone: [MeetingMetricsTestSupport.interval(0, 1)],
                system: [MeetingMetricsTestSupport.interval(0.5, 1)]
            )
            let short = MeetingMetricsMath.overlapSeconds(
                microphone: [MeetingMetricsTestSupport.interval(0, 1)],
                system: [MeetingMetricsTestSupport.interval(0.6, 1)]
            )
            let split = MeetingMetricsMath.overlapSeconds(
                microphone: [
                    MeetingMetricsTestSupport.interval(0, 0.6),
                    MeetingMetricsTestSupport.interval(2, 2.4),
                ],
                system: [
                    MeetingMetricsTestSupport.interval(0, 0.6),
                    MeetingMetricsTestSupport.interval(2, 2.4),
                ]
            )
            #expect(multiple == 7)
            #expect(exact == 0.5)
            #expect(short == 0)
            #expect(abs(split - 0.6) < 0.000_001)
        }

        @Test
        func turnGapUsesStrictGreaterThanBoundary() {
            #expect(MeetingMetricsMath.turnCount([
                MeetingMetricsTestSupport.interval(0, 1),
                MeetingMetricsTestSupport.interval(3, 4),
            ]) == 1)
            #expect(MeetingMetricsMath.turnCount([
                MeetingMetricsTestSupport.interval(0, 1),
                MeetingMetricsTestSupport.interval(3.1, 4),
            ]) == 2)
        }

        @Test
        func unknownContributesOnlyToConversationUnion() {
            let meetingId = UUID.v7()
            let records = [
                MeetingMetricsTestSupport.record(meetingId: meetingId, start: 0, end: 100, speakerLabel: "mic"),
                MeetingMetricsTestSupport.record(meetingId: meetingId, start: 100, end: 200, speakerLabel: "system"),
                MeetingMetricsTestSupport.record(meetingId: meetingId, start: 200, end: 300, speakerLabel: nil),
            ]
            let result = MeetingMetricsAnalyzer.analyze(meetingId: meetingId, revision: 0, records: records)
            #expect(result?.conversationTalkSeconds == 300)
            #expect(result?.talkBalance == 0.5)
            #expect(result?.unknownSourceSegmentCount == 1)
        }
    }
#endif
