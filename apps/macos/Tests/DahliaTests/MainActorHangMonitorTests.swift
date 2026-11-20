import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct MainActorHangMonitorTests {
        @Test
        func durationBucketsStartAtTheReportThreshold() {
            #expect(MainActorHangMonitor.durationBucket(milliseconds: 249) == nil)
            #expect(MainActorHangMonitor.durationBucket(milliseconds: 250) == "250ms")
            #expect(MainActorHangMonitor.durationBucket(milliseconds: 999) == "500ms")
            #expect(MainActorHangMonitor.durationBucket(milliseconds: 1000) == "1s")
            #expect(MainActorHangMonitor.durationBucket(milliseconds: 4999) == "2s")
            #expect(MainActorHangMonitor.durationBucket(milliseconds: 60000) == "5sPlus")
        }

        @Test
        func surfaceUsesOnlyMarksFromTwoSecondsBeforeTheStall() {
            let start = SuspendingClock.now
            var state = MainActorHangMonitor.State()
            #expect(MainActorHangMonitor.surface(in: state, stallStartedAt: start) == .other)

            state.surface = .transcript
            state.markedAt = start - .milliseconds(1900)
            #expect(MainActorHangMonitor.surface(in: state, stallStartedAt: start) == .transcript)

            state.markedAt = start + .milliseconds(10)
            #expect(MainActorHangMonitor.surface(in: state, stallStartedAt: start) == .transcript)

            state.markedAt = start - .milliseconds(2100)
            #expect(MainActorHangMonitor.surface(in: state, stallStartedAt: start) == .other)
        }

        @Test
        func hangContextPassesTheSentryAllowlist() {
            var context = MainActorHangMonitor.context(surface: .liveSubtitle, isRecording: true)
            context["source"] = "mainActorHang"
            context["hangDuration"] = "1s"

            #expect(ErrorReportingService.sanitizedContext(context) == context)
            #expect(context["recording"] == "active")
            #expect(context["hangProcess"] == "app")
        }

        @Test
        func hangTagsRejectValuesOutsideTheirFixedSets() {
            #expect(ErrorReportingService.sanitizedContext([
                "source": "mainActorHang",
                "hangSurface": "Weekly sync",
                "hangDuration": "1234ms",
                "recording": "true",
                "hangProcess": "renderer",
            ]) == ["source": "mainActorHang"])
            #expect(ErrorReportingService.sanitizedContext(["hangProcess": "web"]) == ["hangProcess": "web"])
        }
    }
#endif
