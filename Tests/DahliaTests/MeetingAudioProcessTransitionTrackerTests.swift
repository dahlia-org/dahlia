import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct MeetingAudioActivityMonitorTests {
        private static let chromeWebAppBundleIdentifier = "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan"

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
        func recognizesChromeWindowBundleIdentifierFamily() {
            #expect(MeetingAudioWindowCatalog.browserContext(forBundleIdentifier: "com.google.Chrome") == .chrome)
            #expect(MeetingAudioWindowCatalog.browserContext(forBundleIdentifier: "com.google.Chrome.helper.renderer") == .chrome)
            #expect(MeetingAudioWindowCatalog.browserContext(
                forBundleIdentifier: Self.chromeWebAppBundleIdentifier
            ) == .chrome)
            #expect(MeetingAudioWindowCatalog.browserContext(forBundleIdentifier: "com.example.Chrome.app.meet") == nil)
        }

        @Test
        func recognizesChromePWAAsChromeAudioContext() {
            #expect(MeetingAudioProcessCatalog.context(for: Self.chromeWebAppBundleIdentifier) == .chrome)
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
            let disappearedAt = now.advanced(by: .seconds(1))
            let disappeared = tracker.observe([], at: disappearedAt)
            let beforeGrace = tracker.observe([], at: now.advanced(by: .milliseconds(4999)))
            let afterGrace = tracker.observe([], at: now.advanced(by: .seconds(5)))

            #expect(disappeared.lastSeenAt[.zoom] == disappearedAt)
            #expect(tracker.nextDisappearanceDeadline == nil)
            #expect(beforeGrace.activeContexts == [.zoom])
            #expect(beforeGrace.endedContexts.isEmpty)
            #expect(afterGrace.activeContexts.isEmpty)
            #expect(afterGrace.endedContexts == [.zoom])
            #expect(afterGrace.lastSeenAt[.zoom] == disappearedAt)
        }

        @Test
        func reappearanceRestartsDisappearanceGracePeriod() {
            let now = ContinuousClock.now
            var tracker = MeetingAudioProcessTransitionTracker(disappearanceGracePeriod: .seconds(4))

            _ = tracker.observe([.teams], at: now)
            _ = tracker.observe([], at: now.advanced(by: .seconds(3)))
            _ = tracker.observe([.teams], at: now.advanced(by: .seconds(4)))
            #expect(tracker.nextDisappearanceDeadline == nil)
            let retained = tracker.observe([], at: now.advanced(by: .seconds(7)))
            #expect(tracker.nextDisappearanceDeadline == now.advanced(by: .seconds(11)))
            let ended = tracker.observe([], at: now.advanced(by: .seconds(11)))

            #expect(retained.activeContexts == [.teams])
            #expect(ended.endedContexts == [.teams])
        }

        @Test
        func queryFailureInvalidatesActiveObservationEpoch() {
            let now = ContinuousClock.now
            var tracker = MeetingAudioProcessTransitionTracker(disappearanceGracePeriod: .seconds(4))

            _ = tracker.observe([.zoom], at: now)
            _ = tracker.observe([], at: now.advanced(by: .seconds(1)))
            tracker.queryFailed()
            #expect(tracker.nextDisappearanceDeadline == nil)
            let recovered = tracker.observe([], at: now.advanced(by: .seconds(10)))
            let later = tracker.observe([], at: now.advanced(by: .seconds(14)))

            #expect(recovered.isInitial)
            #expect(recovered.activeContexts.isEmpty)
            #expect(recovered.endedContexts.isEmpty)
            #expect(recovered.firstSeenAt[.zoom] == nil)
            #expect(recovered.lastSeenAt[.zoom] == nil)
            #expect(later.endedContexts.isEmpty)
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

        @Test
        func detectsActiveGoogleMeetChromePWAAsChromeContext() {
            let detection = MeetingWindowDetector.detect(in: [
                MeetingWindowInfo(
                    owner: "Google Meet",
                    title: "Google Meet - Meet - cfh-jkbp-nye 🔊",
                    bundleIdentifier: Self.chromeWebAppBundleIdentifier
                ),
            ])

            #expect(detection?.name == "Google Meet")
            #expect(detection?.browserContexts == [.chrome])
        }

        @Test
        func ignoresLandingAndUnrelatedChromePWAWindows() {
            #expect(MeetingWindowDetector.detect(in: [
                MeetingWindowInfo(
                    owner: "Google Meet",
                    title: "Google Meet",
                    bundleIdentifier: Self.chromeWebAppBundleIdentifier
                ),
                MeetingWindowInfo(
                    owner: "Meet",
                    title: "",
                    bundleIdentifier: Self.chromeWebAppBundleIdentifier
                ),
                MeetingWindowInfo(
                    owner: "Google Meet",
                    title: "Google Meet - Calendar",
                    bundleIdentifier: Self.chromeWebAppBundleIdentifier
                ),
                MeetingWindowInfo(
                    owner: "Calendar",
                    title: "abc-defg-hij",
                    bundleIdentifier: "com.google.Chrome.app.example"
                ),
                MeetingWindowInfo(
                    owner: "Calendar",
                    title: "Zoom Meeting",
                    bundleIdentifier: "com.google.Chrome.app.example"
                ),
                MeetingWindowInfo(
                    owner: "Google Meet",
                    title: "Weekly sync",
                    bundleIdentifier: "com.example.meet"
                ),
            ]) == nil)
        }

        @Test
        func chromeTabAndGoogleMeetPWAUseSameContext() {
            let tabDetection = MeetingWindowDetector.detect(in: [
                MeetingWindowInfo(
                    owner: "Google Chrome",
                    title: "Meet - cfh-jkbp-nye",
                    bundleIdentifier: "com.google.Chrome"
                ),
            ])
            let pwaDetection = MeetingWindowDetector.detect(in: [
                MeetingWindowInfo(
                    owner: "Google Meet",
                    title: "Google Meet - Meet - cfh-jkbp-nye 🔊",
                    bundleIdentifier: Self.chromeWebAppBundleIdentifier
                ),
            ])

            #expect(tabDetection?.browserContexts == [.chrome])
            #expect(pwaDetection?.browserContexts == tabDetection?.browserContexts)
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
