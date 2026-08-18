import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct MeetingRecordingActivityTrackerTests {
        @Test
        func recordingStartedBeforeMeetingStopsAfterEligibleMeetingEnds() {
            let now = ContinuousClock.now
            var tracker = MeetingRecordingActivityTracker(minimumRuntime: .seconds(30))
            tracker.recordingDidStart(at: now)

            let started = snapshot(active: [.chrome], started: [.chrome], at: now.advanced(by: .seconds(1)))
            let ended = snapshot(
                ended: [.chrome],
                firstSeenAt: [.chrome: now.advanced(by: .seconds(1))],
                lastSeenAt: [.chrome: now.advanced(by: .seconds(31))],
                at: now.advanced(by: .seconds(31))
            )

            let startResult = tracker.shouldStop(after: started)
            tracker.observeBrowserCorroboration(
                browserContexts: [.chrome],
                observedAudioContexts: [.chrome],
                at: now.advanced(by: .seconds(1))
            )
            tracker.observeBrowserCorroboration(
                browserContexts: [.chrome],
                observedAudioContexts: [.chrome],
                at: now.advanced(by: .seconds(31))
            )
            let endResult = tracker.shouldStop(after: ended)
            #expect(!startResult)
            #expect(endResult)
        }

        @Test
        func recordingStartedDuringMeetingUsesExistingContext() {
            let now = ContinuousClock.now
            var tracker = MeetingRecordingActivityTracker(minimumRuntime: .seconds(30))
            let currentSnapshot = snapshot(
                active: [.zoom],
                firstSeenAt: [.zoom: now.advanced(by: .seconds(-10))],
                lastSeenAt: [.zoom: now],
                at: now
            )
            tracker.recordingDidStart(at: now, currentSnapshot: currentSnapshot)

            let ended = snapshot(
                ended: [.zoom],
                firstSeenAt: [.zoom: now.advanced(by: .seconds(-10))],
                lastSeenAt: [.zoom: now.advanced(by: .seconds(30))],
                at: now.advanced(by: .seconds(30))
            )

            let result = tracker.shouldStop(after: ended)
            #expect(result)
        }

        @Test
        func recordingDoesNotInheritContextRetainedOnlyByDisappearanceGrace() {
            let now = ContinuousClock.now
            let staleStartedAt = now.advanced(by: .seconds(-60))
            var tracker = MeetingRecordingActivityTracker(minimumRuntime: .seconds(30))
            tracker.recordingDidStart(at: now)

            let retainedResult = tracker.shouldStop(after: snapshot(
                active: [.zoom],
                observed: [],
                firstSeenAt: [.zoom: staleStartedAt],
                lastSeenAt: [.zoom: now.advanced(by: .seconds(-1))],
                at: now
            ))
            let endResult = tracker.shouldStop(after: snapshot(
                ended: [.zoom],
                firstSeenAt: [.zoom: staleStartedAt],
                lastSeenAt: [.zoom: now.advanced(by: .seconds(-1))],
                at: now.advanced(by: .seconds(4))
            ))
            let laterResult = tracker.shouldStop(after: snapshot(at: now.advanced(by: .seconds(30))))

            #expect(!retainedResult)
            #expect(!endResult)
            #expect(!laterResult)
        }

        @Test
        func meetingRuntimeDoesNotReplaceMinimumRecordingRuntime() {
            let now = ContinuousClock.now
            var tracker = MeetingRecordingActivityTracker(minimumRuntime: .seconds(30))
            tracker.recordingDidStart(at: now)
            _ = tracker.shouldStop(after: snapshot(
                active: [.zoom],
                firstSeenAt: [.zoom: now.advanced(by: .seconds(-20))],
                lastSeenAt: [.zoom: now],
                at: now
            ))

            let result = tracker.shouldStop(after: snapshot(
                ended: [.zoom],
                firstSeenAt: [.zoom: now.advanced(by: .seconds(-20))],
                lastSeenAt: [.zoom: now.advanced(by: .seconds(10))],
                at: now.advanced(by: .seconds(10))
            ))
            let scheduledDeadline = tracker.nextEvaluationDeadline
            let beforeDeadline = tracker.shouldStop(at: now.advanced(by: .milliseconds(29999)))
            let atDeadline = tracker.shouldStop(at: now.advanced(by: .seconds(30)))

            #expect(!result)
            #expect(scheduledDeadline == now.advanced(by: .seconds(30)))
            #expect(!beforeDeadline)
            #expect(atDeadline)
        }

        @Test
        func browserCorroborationCancelsAndExpiredGapRestoresPendingStopDeadline() {
            let now = ContinuousClock.now
            var tracker = MeetingRecordingActivityTracker(minimumRuntime: .seconds(30))
            tracker.recordingDidStart(at: now)
            _ = tracker.shouldStop(after: snapshot(
                active: [.chrome, .zoom],
                observed: [.chrome, .zoom],
                firstSeenAt: [.chrome: now, .zoom: now.advanced(by: .seconds(-20))],
                lastSeenAt: [.chrome: now, .zoom: now],
                at: now
            ))
            _ = tracker.shouldStop(after: snapshot(
                active: [.chrome],
                observed: [.chrome],
                ended: [.zoom],
                firstSeenAt: [.chrome: now, .zoom: now.advanced(by: .seconds(-20))],
                lastSeenAt: [.chrome: now.advanced(by: .seconds(10)), .zoom: now.advanced(by: .seconds(10))],
                at: now.advanced(by: .seconds(10))
            ))
            let scheduledDeadline = tracker.nextEvaluationDeadline

            tracker.observeBrowserCorroboration(
                browserContexts: [.chrome],
                observedAudioContexts: [.chrome],
                at: now.advanced(by: .seconds(11))
            )
            let deadlineDuringBrowserMeeting = tracker.nextEvaluationDeadline
            tracker.observeBrowserCorroboration(
                browserContexts: [],
                observedAudioContexts: [.chrome],
                at: now.advanced(by: .seconds(12))
            )
            tracker.observeBrowserCorroboration(
                browserContexts: [],
                observedAudioContexts: [.chrome],
                at: now.advanced(by: .seconds(16))
            )
            let restoredDeadline = tracker.nextEvaluationDeadline
            let stopAfterBrowserGap = tracker.shouldStop(at: now.advanced(by: .seconds(30)))

            #expect(scheduledDeadline == now.advanced(by: .seconds(30)))
            #expect(deadlineDuringBrowserMeeting == nil)
            #expect(restoredDeadline == now.advanced(by: .seconds(30)))
            #expect(stopAfterBrowserGap)
        }

        @Test
        func queryFailureDoesNotQualifyShortNativeContextDuringOutage() {
            let now = ContinuousClock.now
            var tracker = MeetingRecordingActivityTracker(minimumRuntime: .seconds(30))
            tracker.recordingDidStart(at: now)
            _ = tracker.shouldStop(after: snapshot(
                active: [.zoom],
                firstSeenAt: [.zoom: now],
                lastSeenAt: [.zoom: now],
                at: now
            ))

            tracker.audioObservationFailed()
            let recovered = snapshot(
                active: [.zoom],
                firstSeenAt: [.zoom: now.advanced(by: .seconds(40))],
                lastSeenAt: [.zoom: now.advanced(by: .seconds(40))],
                at: now.advanced(by: .seconds(40))
            )
            tracker.recordingDidStart(
                at: now.advanced(by: .seconds(40)),
                currentSnapshot: recovered
            )
            let result = tracker.shouldStop(after: snapshot(
                ended: [.zoom],
                firstSeenAt: [.zoom: now.advanced(by: .seconds(40))],
                lastSeenAt: [.zoom: now.advanced(by: .seconds(50))],
                at: now.advanced(by: .seconds(54))
            ))

            #expect(!result)
        }

        @Test
        func queryFailureRequiresNativeContextToQualifyAgain() {
            let now = ContinuousClock.now
            var tracker = MeetingRecordingActivityTracker(minimumRuntime: .seconds(30))
            tracker.recordingDidStart(at: now)
            _ = tracker.shouldStop(after: snapshot(
                active: [.zoom],
                firstSeenAt: [.zoom: now],
                lastSeenAt: [.zoom: now.advanced(by: .seconds(30))],
                at: now.advanced(by: .seconds(30))
            ))

            tracker.audioObservationFailed()
            let recovered = snapshot(
                active: [.zoom],
                firstSeenAt: [.zoom: now.advanced(by: .seconds(32))],
                lastSeenAt: [.zoom: now.advanced(by: .seconds(32))],
                at: now.advanced(by: .seconds(32))
            )
            tracker.recordingDidStart(
                at: now.advanced(by: .seconds(32)),
                currentSnapshot: recovered
            )
            let result = tracker.shouldStop(after: snapshot(
                ended: [.zoom],
                firstSeenAt: [.zoom: now.advanced(by: .seconds(32))],
                lastSeenAt: [.zoom: now.advanced(by: .seconds(33))],
                at: now.advanced(by: .seconds(37))
            ))

            #expect(!result)
        }

        @Test
        func queryFailureClearsEndedContextFromPreviousObservationEpoch() {
            let now = ContinuousClock.now
            var tracker = MeetingRecordingActivityTracker(minimumRuntime: .seconds(30))
            tracker.recordingDidStart(at: now)
            _ = tracker.shouldStop(after: snapshot(
                active: [.teams, .zoom],
                firstSeenAt: [.teams: now, .zoom: now],
                lastSeenAt: [.teams: now.advanced(by: .seconds(30)), .zoom: now.advanced(by: .seconds(30))],
                at: now.advanced(by: .seconds(30))
            ))

            let zoomEnded = tracker.shouldStop(after: snapshot(
                active: [.teams],
                ended: [.zoom],
                firstSeenAt: [.teams: now, .zoom: now],
                lastSeenAt: [.teams: now.advanced(by: .seconds(31)), .zoom: now.advanced(by: .seconds(31))],
                at: now.advanced(by: .seconds(35))
            ))
            tracker.audioObservationFailed()
            let recovered = snapshot(at: now.advanced(by: .seconds(37)))
            tracker.recordingDidStart(
                at: now.advanced(by: .seconds(37)),
                currentSnapshot: recovered
            )
            let recoveryResult = tracker.shouldStop(after: recovered)

            #expect(!zoomEnded)
            #expect(!recoveryResult)
        }

        @Test
        func shortContextDoesNotStopRecording() {
            let now = ContinuousClock.now
            var tracker = MeetingRecordingActivityTracker(minimumRuntime: .seconds(30))
            tracker.recordingDidStart(at: now)

            _ = tracker.shouldStop(after: snapshot(active: [.slack], started: [.slack], at: now))
            let ended = snapshot(
                ended: [.slack],
                firstSeenAt: [.slack: now],
                lastSeenAt: [.slack: now.advanced(by: .seconds(10))],
                at: now.advanced(by: .seconds(10))
            )

            let result = tracker.shouldStop(after: ended)
            #expect(!result)
        }

        @Test
        func disappearanceGraceDoesNotCountTowardMinimumContextRuntime() {
            let now = ContinuousClock.now
            var tracker = MeetingRecordingActivityTracker(minimumRuntime: .seconds(30))
            tracker.recordingDidStart(at: now)
            _ = tracker.shouldStop(after: snapshot(
                active: [.teams],
                firstSeenAt: [.teams: now],
                lastSeenAt: [.teams: now],
                at: now
            ))

            let ended = snapshot(
                ended: [.teams],
                firstSeenAt: [.teams: now],
                lastSeenAt: [.teams: now.advanced(by: .seconds(26))],
                at: now.advanced(by: .seconds(30))
            )

            let result = tracker.shouldStop(after: ended)
            #expect(!result)
        }

        @Test
        func reappearingContextMustSatisfyMinimumRuntimeAgain() {
            let now = ContinuousClock.now
            var tracker = MeetingRecordingActivityTracker(minimumRuntime: .seconds(30))
            tracker.recordingDidStart(at: now)

            _ = tracker.shouldStop(after: snapshot(
                active: [.chrome],
                started: [.chrome],
                firstSeenAt: [.chrome: now],
                lastSeenAt: [.chrome: now],
                at: now
            ))
            tracker.observeBrowserCorroboration(
                browserContexts: [.chrome],
                observedAudioContexts: [.chrome],
                at: now
            )
            let firstEndResult = tracker.shouldStop(after: snapshot(
                ended: [.chrome],
                firstSeenAt: [.chrome: now],
                lastSeenAt: [.chrome: now.advanced(by: .seconds(20))],
                at: now.advanced(by: .seconds(24))
            ))
            _ = tracker.shouldStop(after: snapshot(
                active: [.chrome],
                started: [.chrome],
                firstSeenAt: [.chrome: now.advanced(by: .seconds(25))],
                lastSeenAt: [.chrome: now.advanced(by: .seconds(25))],
                at: now.advanced(by: .seconds(25))
            ))
            tracker.observeBrowserCorroboration(
                browserContexts: [.chrome],
                observedAudioContexts: [.chrome],
                at: now.advanced(by: .seconds(25))
            )
            let secondEndResult = tracker.shouldStop(after: snapshot(
                ended: [.chrome],
                firstSeenAt: [.chrome: now.advanced(by: .seconds(25))],
                lastSeenAt: [.chrome: now.advanced(by: .seconds(35))],
                at: now.advanced(by: .seconds(39))
            ))

            #expect(!firstEndResult)
            #expect(!secondEndResult)
        }

        @Test
        func waitsUntilAllArmedContextsAreAbsent() {
            let now = ContinuousClock.now
            let startedAt = now.advanced(by: .seconds(-30))
            var tracker = MeetingRecordingActivityTracker(minimumRuntime: .seconds(30))
            tracker.recordingDidStart(at: now)
            _ = tracker.shouldStop(after: snapshot(
                active: [.zoom, .chrome],
                firstSeenAt: [.zoom: startedAt, .chrome: startedAt],
                lastSeenAt: [.zoom: now, .chrome: now],
                at: now
            ))
            tracker.observeBrowserCorroboration(
                browserContexts: [.chrome],
                observedAudioContexts: [.chrome],
                at: now
            )
            tracker.observeBrowserCorroboration(
                browserContexts: [.chrome],
                observedAudioContexts: [.chrome],
                at: now.advanced(by: .seconds(30))
            )

            let zoomEnded = snapshot(
                active: [.chrome],
                ended: [.zoom],
                firstSeenAt: [.zoom: startedAt, .chrome: startedAt],
                lastSeenAt: [.zoom: now.advanced(by: .seconds(30)), .chrome: now.advanced(by: .seconds(30))],
                at: now.advanced(by: .seconds(30))
            )
            let chromeEnded = snapshot(
                ended: [.chrome],
                firstSeenAt: [.chrome: startedAt],
                lastSeenAt: [.chrome: now.advanced(by: .seconds(31))],
                at: now.advanced(by: .seconds(31))
            )

            let zoomResult = tracker.shouldStop(after: zoomEnded)
            let chromeResult = tracker.shouldStop(after: chromeEnded)
            #expect(!zoomResult)
            #expect(chromeResult)
        }

        @Test
        func offlineRecordingWithoutSupportedContextDoesNotStop() {
            let now = ContinuousClock.now
            var tracker = MeetingRecordingActivityTracker(minimumRuntime: .seconds(30))
            tracker.recordingDidStart(at: now)

            let result = tracker.shouldStop(after: snapshot(at: now.advanced(by: .seconds(300))))
            #expect(!result)
        }
    }

    struct BrowserMeetingRecordingActivityTrackerTests {
        @Test
        func uncorroboratedBrowserActivityDoesNotStopRecording() {
            let now = ContinuousClock.now
            var tracker = MeetingRecordingActivityTracker(minimumRuntime: .seconds(30))
            tracker.recordingDidStart(at: now)

            _ = tracker.shouldStop(after: snapshot(active: [.chrome], started: [.chrome], at: now))
            let result = tracker.shouldStop(after: snapshot(
                ended: [.chrome],
                firstSeenAt: [.chrome: now],
                lastSeenAt: [.chrome: now.advanced(by: .seconds(30))],
                at: now.advanced(by: .seconds(30))
            ))

            #expect(!result)
        }

        @Test
        func browserCorroborationMustRemainContinuousForMinimumRuntime() {
            let now = ContinuousClock.now
            let rawAudioStartedAt = now.advanced(by: .seconds(-60))
            var tracker = MeetingRecordingActivityTracker(minimumRuntime: .seconds(30))
            tracker.recordingDidStart(at: now)

            _ = tracker.shouldStop(after: snapshot(
                active: [.chrome],
                started: [.chrome],
                firstSeenAt: [.chrome: rawAudioStartedAt],
                lastSeenAt: [.chrome: now],
                at: now
            ))
            tracker.observeBrowserCorroboration(
                browserContexts: [.chrome],
                observedAudioContexts: [.chrome],
                at: now
            )
            tracker.observeBrowserCorroboration(
                browserContexts: [],
                observedAudioContexts: [.chrome],
                at: now.advanced(by: .seconds(10))
            )
            tracker.observeBrowserCorroboration(
                browserContexts: [.chrome],
                observedAudioContexts: [.chrome],
                at: now.advanced(by: .seconds(20))
            )

            let result = tracker.shouldStop(after: snapshot(
                ended: [.chrome],
                firstSeenAt: [.chrome: rawAudioStartedAt],
                lastSeenAt: [.chrome: now.advanced(by: .seconds(40))],
                at: now.advanced(by: .seconds(44))
            ))

            #expect(!result)
        }

        @Test
        func chromeTabToPWATransitionKeepsQualificationAcrossShortWindowGap() {
            let now = ContinuousClock.now
            var tracker = MeetingRecordingActivityTracker(
                minimumRuntime: .seconds(30),
                browserTransitionGracePeriod: .seconds(4)
            )
            tracker.recordingDidStart(at: now)

            _ = tracker.shouldStop(after: snapshot(active: [.chrome], started: [.chrome], at: now))
            tracker.observeBrowserCorroboration(
                browserContexts: [.chrome],
                observedAudioContexts: [.chrome],
                at: now
            )
            tracker.observeBrowserCorroboration(
                browserContexts: [],
                observedAudioContexts: [.chrome],
                at: now.advanced(by: .seconds(15))
            )
            tracker.observeBrowserCorroboration(
                browserContexts: [.chrome],
                observedAudioContexts: [.chrome],
                at: now.advanced(by: .seconds(18))
            )
            tracker.observeBrowserCorroboration(
                browserContexts: [.chrome],
                observedAudioContexts: [.chrome],
                at: now.advanced(by: .seconds(30))
            )

            let result = tracker.shouldStop(after: snapshot(
                ended: [.chrome],
                firstSeenAt: [.chrome: now],
                lastSeenAt: [.chrome: now.advanced(by: .seconds(31))],
                at: now.advanced(by: .seconds(35))
            ))

            #expect(result)
        }

        @Test
        func chromeTabToPWAGapBeyondGraceRestartsQualification() {
            let now = ContinuousClock.now
            var tracker = MeetingRecordingActivityTracker(
                minimumRuntime: .seconds(30),
                browserTransitionGracePeriod: .seconds(4)
            )
            tracker.recordingDidStart(at: now)

            _ = tracker.shouldStop(after: snapshot(active: [.chrome], started: [.chrome], at: now))
            tracker.observeBrowserCorroboration(
                browserContexts: [.chrome],
                observedAudioContexts: [.chrome],
                at: now
            )
            tracker.observeBrowserCorroboration(
                browserContexts: [],
                observedAudioContexts: [.chrome],
                at: now.advanced(by: .seconds(15))
            )
            tracker.observeBrowserCorroboration(
                browserContexts: [.chrome],
                observedAudioContexts: [.chrome],
                at: now.advanced(by: .seconds(20))
            )
            tracker.observeBrowserCorroboration(
                browserContexts: [.chrome],
                observedAudioContexts: [.chrome],
                at: now.advanced(by: .seconds(30))
            )

            let result = tracker.shouldStop(after: snapshot(
                ended: [.chrome],
                firstSeenAt: [.chrome: now],
                lastSeenAt: [.chrome: now.advanced(by: .seconds(31))],
                at: now.advanced(by: .seconds(35))
            ))

            #expect(!result)
        }

        @Test
        func browserAudioInterruptionBeforeWindowScanRestartsQualification() {
            let now = ContinuousClock.now
            var tracker = MeetingRecordingActivityTracker(minimumRuntime: .seconds(30))
            tracker.recordingDidStart(at: now)

            _ = tracker.shouldStop(after: snapshot(
                active: [.chrome],
                observed: [.chrome],
                started: [.chrome],
                firstSeenAt: [.chrome: now],
                lastSeenAt: [.chrome: now],
                at: now
            ))
            tracker.observeBrowserCorroboration(
                browserContexts: [.chrome],
                observedAudioContexts: [.chrome],
                at: now
            )
            _ = tracker.shouldStop(after: snapshot(
                active: [.chrome],
                observed: [],
                firstSeenAt: [.chrome: now],
                lastSeenAt: [.chrome: now.advanced(by: .seconds(28))],
                at: now.advanced(by: .seconds(29))
            ))
            _ = tracker.shouldStop(after: snapshot(
                active: [.chrome],
                observed: [.chrome],
                firstSeenAt: [.chrome: now],
                lastSeenAt: [.chrome: now.advanced(by: .seconds(30))],
                at: now.advanced(by: .seconds(30))
            ))
            tracker.observeBrowserCorroboration(
                browserContexts: [.chrome],
                observedAudioContexts: [.chrome],
                at: now.advanced(by: .seconds(30))
            )

            let result = tracker.shouldStop(after: snapshot(
                ended: [.chrome],
                firstSeenAt: [.chrome: now],
                lastSeenAt: [.chrome: now.advanced(by: .seconds(35))],
                at: now.advanced(by: .seconds(39))
            ))

            #expect(!result)
        }

        @Test
        func staleWindowScanCannotQualifyShortBrowserAudioActivity() {
            let now = ContinuousClock.now
            var tracker = MeetingRecordingActivityTracker(minimumRuntime: .seconds(30))
            tracker.recordingDidStart(at: now)

            tracker.observeBrowserCorroboration(
                browserContexts: [.chrome],
                observedAudioContexts: [.chrome],
                at: now
            )
            tracker.observeBrowserCorroboration(
                browserContexts: [.chrome],
                observedAudioContexts: [.chrome],
                at: now.advanced(by: .seconds(30))
            )
            _ = tracker.shouldStop(after: snapshot(
                active: [.chrome],
                observed: [],
                firstSeenAt: [.chrome: now],
                lastSeenAt: [.chrome: now.advanced(by: .milliseconds(29100))],
                at: now.advanced(by: .milliseconds(30100))
            ))

            let result = tracker.shouldStop(after: snapshot(
                ended: [.chrome],
                firstSeenAt: [.chrome: now],
                lastSeenAt: [.chrome: now.advanced(by: .milliseconds(29100))],
                at: now.advanced(by: .milliseconds(34100))
            ))

            #expect(!result)
        }

        @Test
        func qualifiedChromeAudioContinuesWhenPWAWindowDisappears() {
            let now = ContinuousClock.now
            var tracker = MeetingRecordingActivityTracker(minimumRuntime: .seconds(30))
            tracker.recordingDidStart(at: now)

            _ = tracker.shouldStop(after: snapshot(active: [.chrome], started: [.chrome], at: now))
            tracker.observeBrowserCorroboration(
                browserContexts: [.chrome],
                observedAudioContexts: [.chrome],
                at: now
            )
            tracker.observeBrowserCorroboration(
                browserContexts: [.chrome],
                observedAudioContexts: [.chrome],
                at: now.advanced(by: .seconds(30))
            )
            tracker.observeBrowserCorroboration(
                browserContexts: [],
                observedAudioContexts: [.chrome],
                at: now.advanced(by: .seconds(31))
            )

            let result = tracker.shouldStop(after: snapshot(
                active: [.chrome],
                firstSeenAt: [.chrome: now],
                lastSeenAt: [.chrome: now.advanced(by: .seconds(31))],
                at: now.advanced(by: .seconds(31))
            ))

            #expect(!result)
        }

        @Test
        func waitsForEveryCorroboratedBrowserContextToEnd() {
            let now = ContinuousClock.now
            var tracker = MeetingRecordingActivityTracker(minimumRuntime: .seconds(30))
            tracker.recordingDidStart(at: now)

            let browsers: Set<MeetingAudioContext> = [.chrome, .edge]
            _ = tracker.shouldStop(after: snapshot(
                active: browsers,
                started: browsers,
                firstSeenAt: [.chrome: now, .edge: now],
                lastSeenAt: [.chrome: now, .edge: now],
                at: now
            ))
            tracker.observeBrowserCorroboration(
                browserContexts: browsers,
                observedAudioContexts: browsers,
                at: now
            )
            tracker.observeBrowserCorroboration(
                browserContexts: browsers,
                observedAudioContexts: browsers,
                at: now.advanced(by: .seconds(30))
            )

            let chromeResult = tracker.shouldStop(after: snapshot(
                active: [.edge],
                ended: [.chrome],
                firstSeenAt: [.chrome: now, .edge: now],
                lastSeenAt: [.chrome: now.advanced(by: .seconds(30)), .edge: now.advanced(by: .seconds(30))],
                at: now.advanced(by: .seconds(34))
            ))
            let edgeResult = tracker.shouldStop(after: snapshot(
                ended: [.edge],
                firstSeenAt: [.edge: now],
                lastSeenAt: [.edge: now.advanced(by: .seconds(31))],
                at: now.advanced(by: .seconds(35))
            ))

            #expect(!chromeResult)
            #expect(edgeResult)
        }
    }

    private func snapshot(
        active: Set<MeetingAudioContext> = [],
        observed: Set<MeetingAudioContext>? = nil,
        started: Set<MeetingAudioContext> = [],
        ended: Set<MeetingAudioContext> = [],
        firstSeenAt: [MeetingAudioContext: ContinuousClock.Instant] = [:],
        lastSeenAt: [MeetingAudioContext: ContinuousClock.Instant] = [:],
        at instant: ContinuousClock.Instant
    ) -> MeetingAudioActivityMonitor.Snapshot {
        MeetingAudioActivityMonitor.Snapshot(
            observedContexts: observed ?? active,
            activeContexts: active,
            startedContexts: started,
            endedContexts: ended,
            firstSeenAt: firstSeenAt,
            lastSeenAt: lastSeenAt,
            observedAt: instant,
            isInitial: false
        )
    }
#endif
