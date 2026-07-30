import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct MeetingMetricsAnalyzerTests {
        @Test
        func blankSegmentsAreExcluded() {
            let meetingId = UUID.v7()
            let result = analyze(meetingId: meetingId, records: [
                MeetingMetricsTestSupport.record(meetingId: meetingId, start: 10, end: 20, text: " \n "),
                MeetingMetricsTestSupport.record(meetingId: meetingId, start: 20, end: 30),
            ])
            #expect(result?.confirmedSegmentCount == 1)
            #expect(result?.validSegmentCount == 1)
        }

        @Test
        func invalidDurationsRemainInCoverageOnly() {
            let meetingId = UUID.v7()
            let result = analyze(meetingId: meetingId, records: [
                MeetingMetricsTestSupport.record(meetingId: meetingId, start: 0, end: nil, text: "abcd"),
                MeetingMetricsTestSupport.record(meetingId: meetingId, start: 2, end: 1, text: "ef"),
                MeetingMetricsTestSupport.record(meetingId: meetingId, start: 3, end: 4, text: "gh"),
            ])
            #expect(result?.confirmedSegmentCount == 3)
            #expect(result?.invalidDurationSegmentCount == 2)
            #expect(result?.validSegmentCount == 1)
            #expect(result?.totalCharacterCount == 8)
            #expect(result?.validCharacterCount == 2)
            #expect(result?.conversationTalkSeconds == 1)
        }

        @Test
        func noValidSegmentsReturnsNil() {
            let meetingId = UUID.v7()
            #expect(analyze(meetingId: meetingId, records: [
                MeetingMetricsTestSupport.record(meetingId: meetingId, start: 0, end: nil),
            ]) == nil)
        }

        @Test
        func countsExtendedGraphemeClustersAndCJK() throws {
            let meetingId = UUID.v7()
            let result = try #require(analyze(meetingId: meetingId, records: [
                MeetingMetricsTestSupport.record(
                    meetingId: meetingId,
                    start: 0,
                    end: 60,
                    text: "日 e\u{301} 👨‍👩‍👧‍👦"
                ),
            ]))
            let row = try #require(result.source(.microphone))
            #expect(row.characterCount == 3)
            #expect(row.cjkCharacterCount == 1)
        }

        @Test
        func unknownLabelsAreCounted() {
            let meetingId = UUID.v7()
            let result = analyze(meetingId: meetingId, records: [
                MeetingMetricsTestSupport.record(meetingId: meetingId, start: 0, end: 1, text: "abc", speakerLabel: nil),
                MeetingMetricsTestSupport.record(meetingId: meetingId, start: 1, end: 2, text: "de", speakerLabel: "other"),
            ])
            #expect(result?.unknownSourceSegmentCount == 2)
            #expect(result?.unknownSourceCharacterCount == 5)
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
