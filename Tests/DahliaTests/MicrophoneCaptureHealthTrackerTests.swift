import AVFoundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct MicrophoneCaptureHealthTrackerTests {
        @Test
        func tracksBuffersLevelsAndIntervalSnapshots() throws {
            let tracker = MicrophoneCaptureHealthTracker()
            let captureID = UUID.v7()
            let start = ContinuousClock.now
            tracker.begin(captureID: captureID, at: start)

            #expect(tracker.recordBuffer(captureID: captureID, frameLength: 480, at: start))
            tracker.recordLevel(0.25, captureID: captureID)
            #expect(!tracker.recordBuffer(
                captureID: captureID,
                frameLength: 480,
                at: start.advanced(by: .seconds(1))
            ))

            let first = try #require(tracker.snapshot(
                captureID: captureID,
                at: start.advanced(by: .seconds(5))
            ))
            #expect(first.intervalBufferCount == 2)
            #expect(first.totalBufferCount == 2)
            #expect(first.totalFrameCount == 960)
            #expect(first.lastLevel == 0.25)
            #expect(first.lastBufferAge == .seconds(4))

            let second = try #require(tracker.snapshot(
                captureID: captureID,
                at: start.advanced(by: .seconds(10))
            ))
            #expect(second.intervalBufferCount == 0)
            #expect(second.totalBufferCount == 2)
        }

        @Test
        func finishReturnsSummaryAndResetsTracker() throws {
            let tracker = MicrophoneCaptureHealthTracker()
            let captureID = UUID.v7()
            let start = ContinuousClock.now
            tracker.begin(captureID: captureID, at: start)
            _ = tracker.recordBuffer(captureID: captureID, frameLength: 240, at: start)

            let summary = try #require(tracker.finish(
                captureID: captureID,
                at: start.advanced(by: .seconds(2))
            ))

            #expect(summary.totalBufferCount == 1)
            #expect(summary.totalFrameCount == 240)
            #expect(tracker.snapshot(captureID: captureID) == nil)
        }
    }
#endif
