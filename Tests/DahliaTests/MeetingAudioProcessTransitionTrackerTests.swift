import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct MeetingAudioActivityMonitorTests {
        @Test
        func recognizesNativeAndBrowserAudioProcesses() {
            let contexts = MeetingAudioProcessCatalog.contexts(for: [
                "us.zoom.caphost",
                "com.microsoft.teams2.audio",
                "com.tinyspeck.slackmacgap.helper",
                "com.google.Chrome.helper.renderer",
                "company.thebrowser.Browser.helper",
                "org.mozilla.firefox",
                "com.openai.atlas.web.helper",
                "ai.perplexity.comet.helper",
            ])

            #expect(contexts == [
                .zoom, .teams, .slack, .chrome, .arc, .firefox, .atlas, .comet,
            ])
        }

        @Test
        func ignoresUnrecognizedAudioProcesses() {
            #expect(MeetingAudioProcessCatalog.contexts(for: [
                "com.example.voice-recorder",
                "com.apple.WebKit.GPU",
            ]).isEmpty)
        }

        @Test
        func recognizesOnlyBrowserSpecificMeetingWindows() {
            #expect(MeetingAudioWindowCatalog.browserContext(forApplicationName: "Google Chrome") == .chrome)
            #expect(MeetingAudioWindowCatalog.browserContext(forApplicationName: "Arc") == .arc)
            #expect(MeetingAudioWindowCatalog.browserContext(forApplicationName: "Safari") == nil)
            #expect(MeetingAudioWindowCatalog.browserContext(forApplicationName: "Example App") == nil)
        }

        @Test
        func initialSnapshotDoesNotReportMeetingStart() {
            let now = ContinuousClock.now
            var tracker = MeetingAudioProcessTransitionTracker()

            let snapshot = tracker.observe([.chrome], at: now)

            #expect(snapshot.isInitial)
            #expect(snapshot.activeContexts == [.chrome])
            #expect(snapshot.startedContexts.isEmpty)
            #expect(snapshot.endedContexts.isEmpty)
        }

        @Test
        func reportsEachContextStartOnlyOnce() {
            let now = ContinuousClock.now
            var tracker = MeetingAudioProcessTransitionTracker()

            _ = tracker.observe([], at: now)
            let started = tracker.observe([.chrome], at: now.advanced(by: .seconds(1)))
            let unchanged = tracker.observe([.chrome], at: now.advanced(by: .seconds(2)))

            #expect(started.startedContexts == [.chrome])
            #expect(unchanged.startedContexts.isEmpty)
        }

        @Test
        func startNotificationPlannerIgnoresInitialAndRecordingSnapshots() {
            let now = ContinuousClock.now
            let initial = snapshot(started: [.zoom], at: now, isInitial: true)
            let whileRecording = snapshot(started: [.zoom], at: now, isInitial: false)

            #expect(MeetingStartNotificationPlanner.context(for: initial, isRecording: false) == nil)
            #expect(MeetingStartNotificationPlanner.context(for: whileRecording, isRecording: true) == nil)
        }

        @Test
        func startNotificationPlannerSupportsNativeAppsAndBrowsers() {
            let now = ContinuousClock.now

            #expect(MeetingStartNotificationPlanner.context(
                for: snapshot(started: [.teams], at: now, isInitial: false),
                isRecording: false
            ) == .teams)
            #expect(MeetingStartNotificationPlanner.context(
                for: snapshot(started: [.chrome], at: now, isInitial: false),
                isRecording: false
            ) == .chrome)
        }

        @Test
        func startNotificationPlannerCoalescesSimultaneousStartsByStablePriority() {
            let candidate = MeetingStartNotificationPlanner.context(
                for: snapshot(
                    started: [.chrome, .teams, .zoom],
                    at: ContinuousClock.now,
                    isInitial: false
                ),
                isRecording: false
            )

            #expect(candidate == .zoom)
        }

        @Test
        func notificationMetadataIsAvailableForEverySupportedContext() {
            for context in MeetingAudioContext.allCases {
                let application = context.notificationApplication
                #expect(!application.name.isEmpty)
                #expect(!application.bundleIdentifier.isEmpty)
            }
        }

        @Test(arguments: [
            (startNotificationsEnabled: true, automaticStopEnabled: false, isRecording: false, expected: true),
            (startNotificationsEnabled: true, automaticStopEnabled: false, isRecording: true, expected: false),
            (startNotificationsEnabled: false, automaticStopEnabled: true, isRecording: true, expected: true),
            (startNotificationsEnabled: true, automaticStopEnabled: true, isRecording: true, expected: true),
            (startNotificationsEnabled: false, automaticStopEnabled: false, isRecording: false, expected: false),
            (startNotificationsEnabled: false, automaticStopEnabled: true, isRecording: false, expected: false),
        ])
        func processMonitoringMatchesEnabledConsumers(
            startNotificationsEnabled: Bool,
            automaticStopEnabled: Bool,
            isRecording: Bool,
            expected: Bool
        ) {
            let policy = MeetingAudioMonitoringPolicy(
                startNotificationsEnabled: startNotificationsEnabled,
                automaticStopEnabled: automaticStopEnabled,
                isRecording: isRecording
            )

            #expect(policy.shouldMonitorProcesses == expected)
        }

        @Test
        func browserWindowScanningIsReservedForAutomaticStopDuringRecording() {
            #expect(MeetingAudioMonitoringPolicy(
                startNotificationsEnabled: true,
                automaticStopEnabled: true,
                isRecording: true
            ).shouldScanBrowserWindows)
            #expect(!MeetingAudioMonitoringPolicy(
                startNotificationsEnabled: true,
                automaticStopEnabled: true,
                isRecording: false
            ).shouldScanBrowserWindows)
            #expect(!MeetingAudioMonitoringPolicy(
                startNotificationsEnabled: true,
                automaticStopEnabled: false,
                isRecording: true
            ).shouldScanBrowserWindows)
        }

        @Test
        func multipleHelpersCollapseIntoOneBrowserContext() {
            let contexts = MeetingAudioProcessCatalog.contexts(for: [
                "com.google.Chrome.helper",
                "com.google.Chrome.helper.renderer",
                "com.google.Chrome.helper.plugin",
            ])

            #expect(contexts == [.chrome])
        }

        @Test
        func reportsEndAfterContinuousDisappearanceGracePeriod() {
            let now = ContinuousClock.now
            var tracker = MeetingAudioProcessTransitionTracker(disappearanceGracePeriod: .seconds(4))

            _ = tracker.observe([.zoom], at: now)
            _ = tracker.observe([], at: now.advanced(by: .seconds(1)))
            let beforeGrace = tracker.observe([], at: now.advanced(by: .milliseconds(4999)))
            let afterGrace = tracker.observe([], at: now.advanced(by: .seconds(5)))

            #expect(beforeGrace.activeContexts == [.zoom])
            #expect(beforeGrace.endedContexts.isEmpty)
            #expect(afterGrace.activeContexts.isEmpty)
            #expect(afterGrace.endedContexts == [.zoom])
        }

        @Test
        func reappearanceRestartsDisappearanceGracePeriod() {
            let now = ContinuousClock.now
            var tracker = MeetingAudioProcessTransitionTracker(disappearanceGracePeriod: .seconds(4))

            _ = tracker.observe([.teams], at: now)
            _ = tracker.observe([], at: now.advanced(by: .seconds(3)))
            _ = tracker.observe([.teams], at: now.advanced(by: .seconds(4)))
            let retained = tracker.observe([], at: now.advanced(by: .seconds(7)))
            let ended = tracker.observe([], at: now.advanced(by: .seconds(11)))

            #expect(retained.activeContexts == [.teams])
            #expect(ended.endedContexts == [.teams])
        }

        @Test
        func queryFailureRestartsDisappearanceGracePeriod() {
            let now = ContinuousClock.now
            var tracker = MeetingAudioProcessTransitionTracker(disappearanceGracePeriod: .seconds(4))

            _ = tracker.observe([.zoom], at: now)
            _ = tracker.observe([], at: now.advanced(by: .seconds(1)))
            tracker.queryFailed()
            let recovered = tracker.observe([], at: now.advanced(by: .seconds(10)))
            let beforeGrace = tracker.observe([], at: now.advanced(by: .milliseconds(13999)))
            let afterGrace = tracker.observe([], at: now.advanced(by: .seconds(14)))

            #expect(recovered.activeContexts == [.zoom])
            #expect(beforeGrace.activeContexts == [.zoom])
            #expect(afterGrace.endedContexts == [.zoom])
        }

        @Test
        func detectsAllBrowserContextsFromMeetingWindows() {
            let detection = MeetingWindowDetector.detect(in: [
                MeetingWindowInfo(owner: "Google Chrome", title: "Meet - Weekly sync"),
                MeetingWindowInfo(owner: "Microsoft Edge", title: "abc-defg-hij"),
                MeetingWindowInfo(owner: "Example App", title: "Unrelated"),
            ])

            #expect(detection?.name == "Google Meet")
            #expect(detection?.browserContexts == [.chrome, .edge])
        }

        private func snapshot(
            started: Set<MeetingAudioContext>,
            at instant: ContinuousClock.Instant,
            isInitial: Bool
        ) -> MeetingAudioActivityMonitor.Snapshot {
            MeetingAudioActivityMonitor.Snapshot(
                observedContexts: started,
                activeContexts: started,
                startedContexts: started,
                endedContexts: [],
                firstSeenAt: Dictionary(uniqueKeysWithValues: started.map { ($0, instant) }),
                lastSeenAt: Dictionary(uniqueKeysWithValues: started.map { ($0, instant) }),
                observedAt: instant,
                isInitial: isInitial
            )
        }
    }
#endif
