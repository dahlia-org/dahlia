import Foundation
@testable import Dahlia

#if canImport(Testing)
import Testing

@MainActor
struct TranscriptSegmentTests {
    @Test
    func elapsedHHmmssFormatsDurationFromStartTime() {
        let start = Date(timeIntervalSince1970: 1_776_384_000)

        #expect(Formatters.elapsedHHmmss(from: start, to: start) == "00:00:00")
        #expect(Formatters.elapsedHHmmss(from: start, to: start.addingTimeInterval(754)) == "00:12:34")
        #expect(Formatters.elapsedHHmmss(from: start, to: start.addingTimeInterval(3947)) == "01:05:47")
        #expect(Formatters.elapsedHHmmss(from: start, to: start.addingTimeInterval(-1)) == "00:00:00")
    }

    @Test
    func transcriptStoreExportsRelativeTimestampsFromRecordingStartTime() {
        let store = TranscriptStore()
        let start = Date(timeIntervalSince1970: 1_776_384_000)
        store.recordingStartTime = start
        store.loadSegments([
            TranscriptSegment(
                startTime: start.addingTimeInterval(754),
                text: "First",
                isConfirmed: true,
                speakerLabel: "mic"
            ),
            TranscriptSegment(
                startTime: start.addingTimeInterval(3947),
                text: "Second",
                isConfirmed: true
            ),
        ])

        #expect(store.exportAsText() == "[00:12:34] [mic] First\n[01:05:47] Second")
        #expect(store.exportForSummary() == "<time>00:12:34</time> First\n<time>01:05:47</time> Second")
    }

    @Test
    func transcriptStoreExportsSessionOffsetTimestampsAcrossPausedRecording() {
        let store = TranscriptStore()
        let meetingStart = Date(timeIntervalSince1970: 1_776_384_000)
        let firstSessionId = UUID.v7()
        let secondSessionId = UUID.v7()
        store.recordingStartTime = meetingStart
        store.loadRecordingSessions([
            RecordingSessionTimeline(
                id: firstSessionId,
                startedAt: meetingStart,
                endedAt: meetingStart.addingTimeInterval(10),
                offsetSeconds: 0
            ),
            RecordingSessionTimeline(
                id: secondSessionId,
                startedAt: meetingStart.addingTimeInterval(300),
                endedAt: nil,
                offsetSeconds: 10
            ),
        ])
        store.loadSegments([
            TranscriptSegment(
                sessionId: firstSessionId,
                startTime: meetingStart.addingTimeInterval(5),
                text: "Before pause",
                isConfirmed: true
            ),
            TranscriptSegment(
                sessionId: secondSessionId,
                startTime: meetingStart.addingTimeInterval(303),
                text: "After pause",
                isConfirmed: true
            ),
        ])

        #expect(store.exportAsText() == "[00:00:05] Before pause\n[00:00:13] After pause")
        #expect(store.exportForSummary() == "<time>00:00:05</time> Before pause\n<time>00:00:13</time> After pause")
    }

    @Test
    func transcriptStoreUpdatesTranslatedTextForMatchingSegmentOnly() {
        let store = TranscriptStore()
        let first = TranscriptSegment(
            startTime: Date(timeIntervalSince1970: 1_776_384_000),
            text: "First",
            isConfirmed: true,
            speakerLabel: "mic"
        )
        let second = TranscriptSegment(
            startTime: Date(timeIntervalSince1970: 1_776_384_100),
            text: "Second",
            isConfirmed: true,
            speakerLabel: "system"
        )

        store.loadSegments([first, second])
        store.updateTranslatedText(for: second.id, translatedText: "2つ目")

        #expect(store.segments[0].translatedText == nil)
        #expect(store.segments[1].translatedText == "2つ目")
    }

    @Test
    func transcriptStoreReusesUnconfirmedSegmentIDAndPreservesTranslatedText() async {
        let store = TranscriptStore()
        let first = store.updateUnconfirmedSegment(
            TranscriptSegment(
                startTime: Date(timeIntervalSince1970: 1_776_384_000),
                text: "Hello",
                translatedText: "こんにちは",
                isConfirmed: false,
                speakerLabel: "mic"
            ),
            forSource: "mic"
        )
        await waitForUnconfirmedThrottleWindow()
        let second = store.updateUnconfirmedSegment(
            TranscriptSegment(
                startTime: Date(timeIntervalSince1970: 1_776_384_001),
                text: "Hello world",
                isConfirmed: false,
                speakerLabel: "mic"
            ),
            forSource: "mic"
        )

        #expect(first.id == second.id)
        #expect(store.segments.count == 1)
        #expect(store.segments[0].id == first.id)
        #expect(store.segments[0].translatedText == "こんにちは")
        #expect(store.segments[0].text == "Hello world")
    }

    @Test
    func clearUnconfirmedSegmentsOnlyRemovesMatchingSource() async {
        let store = TranscriptStore()
        store.loadSegments([
            TranscriptSegment(
                startTime: Date(timeIntervalSince1970: 1_776_384_000),
                text: "Confirmed",
                isConfirmed: true,
                speakerLabel: "mic"
            ),
        ])
        store.updateUnconfirmedSegment(
            TranscriptSegment(
                startTime: Date(timeIntervalSince1970: 1_776_384_001),
                text: "Mic preview",
                isConfirmed: false,
                speakerLabel: "mic"
            ),
            forSource: "mic"
        )
        store.updateUnconfirmedSegment(
            TranscriptSegment(
                startTime: Date(timeIntervalSince1970: 1_776_384_002),
                text: "System preview",
                isConfirmed: false,
                speakerLabel: "system"
            ),
            forSource: "system"
        )
        await waitForUnconfirmedThrottleWindow()

        store.clearUnconfirmedSegments(forSource: "mic")

        #expect(store.segments.count == 2)
        #expect(store.segments.contains(where: { $0.text == "Confirmed" && $0.isConfirmed }))
        #expect(store.segments.contains(where: { $0.text == "System preview" && !$0.isConfirmed }))
        #expect(!store.segments.contains(where: { $0.text == "Mic preview" }))
    }

    @Test
    func transcriptSegmentRecordRoundTripsTranslatedText() {
        let meetingID = UUID.v7()
        let segment = TranscriptSegment(
            startTime: Date(timeIntervalSince1970: 1_776_384_000),
            text: "Hello world",
            translatedText: "こんにちは、世界",
            isConfirmed: true,
            speakerLabel: "mic"
        )

        let record = TranscriptSegmentRecord(from: segment, meetingId: meetingID)
        let roundTripped = TranscriptSegment(from: record)

        #expect(record.translatedText == "こんにちは、世界")
        #expect(roundTripped.translatedText == "こんにちは、世界")
    }

    @Test
    func visibleTranslatedTextRespectsSettingAndBlankValues() {
        let segment = TranscriptSegment(
            startTime: Date(timeIntervalSince1970: 1_776_384_000),
            text: "Hello world",
            translatedText: " こんにちは、世界 ",
            isConfirmed: true
        )
        let blankSegment = TranscriptSegment(
            startTime: Date(timeIntervalSince1970: 1_776_384_100),
            text: "Hello world",
            translatedText: "  ",
            isConfirmed: true
        )

        #expect(segment.visibleTranslatedText(isEnabled: true) == "こんにちは、世界")
        #expect(segment.visibleTranslatedText(isEnabled: false) == nil)
        #expect(blankSegment.visibleTranslatedText(isEnabled: true) == nil)
    }
}

#elseif canImport(XCTest)
import XCTest

@MainActor
final class TranscriptSegmentTests: XCTestCase {
    func testTranscriptStoreUpdatesTranslatedTextForMatchingSegmentOnly() {
        let store = TranscriptStore()
        let first = TranscriptSegment(
            startTime: Date(timeIntervalSince1970: 1_776_384_000),
            text: "First",
            isConfirmed: true,
            speakerLabel: "mic"
        )
        let second = TranscriptSegment(
            startTime: Date(timeIntervalSince1970: 1_776_384_100),
            text: "Second",
            isConfirmed: true,
            speakerLabel: "system"
        )

        store.loadSegments([first, second])
        store.updateTranslatedText(for: second.id, translatedText: "2つ目")

        XCTAssertNil(store.segments[0].translatedText)
        XCTAssertEqual(store.segments[1].translatedText, "2つ目")
    }

    func testTranscriptStoreReusesUnconfirmedSegmentIDAndPreservesTranslatedText() async {
        let store = TranscriptStore()
        let first = store.updateUnconfirmedSegment(
            TranscriptSegment(
                startTime: Date(timeIntervalSince1970: 1_776_384_000),
                text: "Hello",
                translatedText: "こんにちは",
                isConfirmed: false,
                speakerLabel: "mic"
            ),
            forSource: "mic"
        )
        await waitForUnconfirmedThrottleWindow()
        let second = store.updateUnconfirmedSegment(
            TranscriptSegment(
                startTime: Date(timeIntervalSince1970: 1_776_384_001),
                text: "Hello world",
                isConfirmed: false,
                speakerLabel: "mic"
            ),
            forSource: "mic"
        )

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(store.segments.count, 1)
        XCTAssertEqual(store.segments[0].id, first.id)
        XCTAssertEqual(store.segments[0].translatedText, "こんにちは")
        XCTAssertEqual(store.segments[0].text, "Hello world")
    }

    func testClearUnconfirmedSegmentsOnlyRemovesMatchingSource() async {
        let store = TranscriptStore()
        store.loadSegments([
            TranscriptSegment(
                startTime: Date(timeIntervalSince1970: 1_776_384_000),
                text: "Confirmed",
                isConfirmed: true,
                speakerLabel: "mic"
            ),
        ])
        store.updateUnconfirmedSegment(
            TranscriptSegment(
                startTime: Date(timeIntervalSince1970: 1_776_384_001),
                text: "Mic preview",
                isConfirmed: false,
                speakerLabel: "mic"
            ),
            forSource: "mic"
        )
        store.updateUnconfirmedSegment(
            TranscriptSegment(
                startTime: Date(timeIntervalSince1970: 1_776_384_002),
                text: "System preview",
                isConfirmed: false,
                speakerLabel: "system"
            ),
            forSource: "system"
        )
        await waitForUnconfirmedThrottleWindow()

        store.clearUnconfirmedSegments(forSource: "mic")

        XCTAssertEqual(store.segments.count, 2)
        XCTAssertTrue(store.segments.contains(where: { $0.text == "Confirmed" && $0.isConfirmed }))
        XCTAssertTrue(store.segments.contains(where: { $0.text == "System preview" && !$0.isConfirmed }))
        XCTAssertFalse(store.segments.contains(where: { $0.text == "Mic preview" }))
    }

    func testTranscriptSegmentRecordRoundTripsTranslatedText() {
        let meetingID = UUID.v7()
        let segment = TranscriptSegment(
            startTime: Date(timeIntervalSince1970: 1_776_384_000),
            text: "Hello world",
            translatedText: "こんにちは、世界",
            isConfirmed: true,
            speakerLabel: "mic"
        )

        let record = TranscriptSegmentRecord(from: segment, meetingId: meetingID)
        let roundTripped = TranscriptSegment(from: record)

        XCTAssertEqual(record.translatedText, "こんにちは、世界")
        XCTAssertEqual(roundTripped.translatedText, "こんにちは、世界")
    }

    func testVisibleTranslatedTextRespectsSettingAndBlankValues() {
        let segment = TranscriptSegment(
            startTime: Date(timeIntervalSince1970: 1_776_384_000),
            text: "Hello world",
            translatedText: " こんにちは、世界 ",
            isConfirmed: true
        )
        let blankSegment = TranscriptSegment(
            startTime: Date(timeIntervalSince1970: 1_776_384_100),
            text: "Hello world",
            translatedText: "  ",
            isConfirmed: true
        )

        XCTAssertEqual(segment.visibleTranslatedText(isEnabled: true), "こんにちは、世界")
        XCTAssertNil(segment.visibleTranslatedText(isEnabled: false))
        XCTAssertNil(blankSegment.visibleTranslatedText(isEnabled: true))
    }
}
#endif

@MainActor
private func waitForUnconfirmedThrottleWindow() async {
    try? await Task.sleep(for: .milliseconds(250))
}
