import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct MeetingMetricsMathTests {
        @Test
        func shippingSweepMergesSameSourceAndProducesOverlap() throws {
            let meetingId = UUID.v7()
            let result = try #require(analyze(meetingId: meetingId, records: [
                MeetingMetricsTestSupport.record(meetingId: meetingId, start: 0, end: 100, speakerLabel: "mic"),
                MeetingMetricsTestSupport.record(meetingId: meetingId, start: 50, end: 150, speakerLabel: "mic"),
                MeetingMetricsTestSupport.record(meetingId: meetingId, start: 70, end: 140, speakerLabel: "system"),
            ]))

            #expect(result.source(.microphone)?.speakingSeconds == 150)
            #expect(result.source(.system)?.speakingSeconds == 70)
            #expect(result.conversationTalkSeconds == 150)
            #expect(result.overlapSeconds == 70)
            #expect(result.sourceComparisonGatePassed)
            #expect(result.talkBalance == 150.0 / 220.0)
        }

        @Test
        func overlapEpisodeMinimumUsesShippingFinalFlush() throws {
            let meetingId = UUID.v7()
            let result = try #require(analyze(meetingId: meetingId, records: [
                MeetingMetricsTestSupport.record(meetingId: meetingId, start: 0, end: 100, speakerLabel: "mic"),
                MeetingMetricsTestSupport.record(meetingId: meetingId, start: 0, end: 0.4, speakerLabel: "system"),
                MeetingMetricsTestSupport.record(meetingId: meetingId, start: 40, end: 100, speakerLabel: "system"),
            ]))

            #expect(result.overlapSeconds == 60)
            #expect(result.conversationTalkSeconds == 100)
        }

        @Test
        func outOfOrderInputHitsTimelineEarlyReturn() throws {
            let meetingId = UUID.v7()
            let result = try #require(analyze(meetingId: meetingId, records: [
                MeetingMetricsTestSupport.record(meetingId: meetingId, start: 10, end: 20, speakerLabel: "mic"),
                MeetingMetricsTestSupport.record(meetingId: meetingId, start: 0, end: 5, speakerLabel: "mic"),
            ]))

            #expect(result.conversationTalkSeconds == 10)
            #expect(result.source(.microphone)?.speakingSeconds == 10)
        }

        @Test
        func turnGapUsesStrictGreaterThanBoundary() throws {
            let meetingId = UUID.v7()
            let boundary = try #require(analyze(meetingId: meetingId, records: [
                MeetingMetricsTestSupport.record(meetingId: meetingId, start: 0, end: 1),
                MeetingMetricsTestSupport.record(meetingId: meetingId, start: 3, end: 4),
            ]))
            let beyond = try #require(analyze(meetingId: meetingId, records: [
                MeetingMetricsTestSupport.record(meetingId: meetingId, start: 0, end: 1),
                MeetingMetricsTestSupport.record(meetingId: meetingId, start: 3.1, end: 4),
            ]))

            #expect(boundary.source(.microphone)?.turnCount == 1)
            #expect(beyond.source(.microphone)?.turnCount == 2)
        }

        @Test
        func unknownContributesOnlyToConversationUnion() throws {
            let meetingId = UUID.v7()
            let result = try #require(analyze(meetingId: meetingId, records: [
                MeetingMetricsTestSupport.record(meetingId: meetingId, start: 0, end: 100, speakerLabel: "mic"),
                MeetingMetricsTestSupport.record(meetingId: meetingId, start: 100, end: 200, speakerLabel: "system"),
                MeetingMetricsTestSupport.record(meetingId: meetingId, start: 200, end: 300, speakerLabel: nil),
            ]))

            #expect(result.conversationTalkSeconds == 300)
            #expect(result.talkBalance == 0.5)
            #expect(result.source(.unknown)?.speakingSeconds == 100)
        }

        private func analyze(
            meetingId: UUID,
            records: [TranscriptSegmentRecord]
        ) -> MeetingMetricsResult? {
            var accumulator = MeetingMetricsAnalyzer.Accumulator(meetingId: meetingId, revision: 0)
            for record in records {
                accumulator.append(MeetingMetricsTestSupport.segment(record))
            }
            return accumulator.finish()
        }
    }
#endif
