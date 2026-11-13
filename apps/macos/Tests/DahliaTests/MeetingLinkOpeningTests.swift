import Foundation
import os
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    @Suite(.serialized)
    struct MeetingLinkOpeningTests {
        @Test
        func preOpeningWindowSnapshotRunsOffMainThread() async throws {
            let settings = AppSettings.shared
            let previousValue = settings.automaticScreenshotSelectsMeetingWindow
            defer { settings.automaticScreenshotSelectsMeetingWindow = previousValue }
            settings.automaticScreenshotSelectsMeetingWindow = true
            let viewModel = CaptionViewModel(
                availableInputDevicesProvider: { [] },
                defaultInputDeviceIDProvider: { nil }
            )
            let ranOnMainThread = OSAllocatedUnfairLock(initialState: true)

            let snapshot = try #require(viewModel.windowTitlesBeforeOpeningMeetingLink {
                ranOnMainThread.withLock { $0 = Thread.isMainThread }
                return [42: "Meeting"]
            })

            #expect(await snapshot.value == [42: "Meeting"])
            #expect(!ranOnMainThread.withLock { $0 })
        }

        @Test
        func servicesResolveFromConferenceHosts() throws {
            #expect(try MeetingLinkService(conferenceURL: url("https://meet.google.com/abc")) == .googleMeet)
            #expect(try MeetingLinkService(conferenceURL: url("https://US06WEB.ZOOM.US/j/123")) == .zoom)
            #expect(try MeetingLinkService(conferenceURL: url("https://teams.microsoft.com/l/meetup-join/abc")) == .teams)
            #expect(try MeetingLinkService(conferenceURL: url("https://app.slack.com/huddle/T1/C1")) == .slack)
            #expect(try MeetingLinkService(conferenceURL: url("https://example.com/meeting")) == nil)
            #expect(MeetingLinkService.allCases == [.googleMeet, .zoom, .teams, .slack])
            #expect(CalendarConferenceURIExtractor.conferenceURI(
                url: nil,
                textFields: ["Join https://workspace.slack.com/huddle/T1/C1"]
            )?.host() == "workspace.slack.com")
            #expect(try CalendarConferenceURIExtractor.conferenceURI(
                url: url("https://workspace.slack.com/archives/C1/p123"),
                textFields: ["See https://workspace.slack.com/archives/C1/p456"]
            ) == nil)
        }

        @Test
        func openTargetsRoundTripAndRejectInvalidValues() {
            let application = MeetingLinkOpenTarget.application(bundleIdentifier: "com.google.Chrome")

            #expect(MeetingLinkOpenTarget(rawValue: application.rawValue) == application)
            #expect(MeetingLinkOpenTarget(rawValue: "inherit") == .inheritGlobal)
            #expect(MeetingLinkOpenTarget(rawValue: "system") == .systemDefault)
            #expect(MeetingLinkOpenTarget(rawValue: "application:") == nil)
            #expect((MeetingLinkOpenTarget(rawValue: "invalid") ?? .systemDefault) == .systemDefault)
        }

        @Test
        func settingsPersistDefaultsAndServiceOverrides() {
            let keys = [
                AppSettings.defaultMeetingLinkOpenTargetUserDefaultsKey,
                AppSettings.googleMeetMeetingLinkOpenTargetUserDefaultsKey,
                AppSettings.zoomMeetingLinkOpenTargetUserDefaultsKey,
                AppSettings.teamsMeetingLinkOpenTargetUserDefaultsKey,
                AppSettings.slackMeetingLinkOpenTargetUserDefaultsKey,
            ]
            let snapshots = keys.map(UserDefaultsValueSnapshot.init)
            defer { snapshots.forEach { $0.restore() } }
            keys.forEach(UserDefaults.standard.removeObject)

            let settings = AppSettings()
            #expect(settings.defaultMeetingLinkOpenTarget == .systemDefault)
            #expect(MeetingLinkService.allCases.allSatisfy {
                settings.meetingLinkOpenTarget(for: $0) == .inheritGlobal
            })
            settings.defaultMeetingLinkOpenTarget = .application(bundleIdentifier: "com.google.Chrome")
            settings.setMeetingLinkOpenTarget(.application(bundleIdentifier: "us.zoom.xos"), for: .zoom)
            settings.googleMeetMeetingLinkOpenTargetRawValue = "invalid"

            let reloadedSettings = AppSettings()
            #expect(reloadedSettings.defaultMeetingLinkOpenTarget == .application(bundleIdentifier: "com.google.Chrome"))
            #expect(reloadedSettings.meetingLinkOpenTarget(for: .zoom) == .application(bundleIdentifier: "us.zoom.xos"))
            #expect(reloadedSettings.meetingLinkOpenTarget(for: .googleMeet) == .inheritGlobal)

            reloadedSettings.defaultMeetingLinkOpenTargetRawValue = MeetingLinkOpenTarget.inheritGlobal.rawValue
            reloadedSettings.normalizeMeetingLinkOpenTargets()
            #expect(reloadedSettings.defaultMeetingLinkOpenTarget == .systemDefault)
            #expect(reloadedSettings.defaultMeetingLinkOpenTargetRawValue == MeetingLinkOpenTarget.systemDefault.rawValue)
        }

        @Test
        func catalogKeepsChromeAndMeetPWAAsSeparateDeduplicatedOptions() {
            let chrome = MeetingLinkApplication(bundleIdentifier: "com.google.Chrome", displayName: "Google Chrome")
            let duplicateChrome = MeetingLinkApplication(bundleIdentifier: "com.google.chrome", displayName: "Chrome")
            let meetPWA = MeetingLinkApplication(
                bundleIdentifier: "com.google.Chrome.app.meet",
                displayName: "Google Meet"
            )
            let zoom = MeetingLinkApplication(bundleIdentifier: "us.zoom.xos", displayName: "Zoom")
            let catalog = MeetingLinkApplicationCatalog(
                globalApplications: [chrome],
                applicationsByService: [
                    .googleMeet: [duplicateChrome, meetPWA],
                    .zoom: [zoom],
                ]
            )

            #expect(catalog.globalApplications.map(\.bundleIdentifier) == ["com.google.Chrome"])
            #expect(Set(catalog.applications(for: .googleMeet).map { $0.bundleIdentifier.lowercased() }) == [
                "com.google.chrome",
                "com.google.chrome.app.meet",
            ])
            #expect(Set(catalog.applications(for: .zoom).map(\.bundleIdentifier)) == ["com.google.Chrome", "us.zoom.xos"])
            #expect(catalog.applications(for: .slack) == [chrome])

            let catalogWithoutPWA = MeetingLinkApplicationCatalog(
                globalApplications: [chrome],
                applicationsByService: [:]
            )
            #expect(catalogWithoutPWA.applications(for: .googleMeet) == [chrome])
        }

        @Test
        func browserDetectionExcludesGenericURLHandlers() {
            let browserInfo = webURLHandlerInfo(documentType: ["LSItemContentTypes": ["public.html"]])
            let browserUsingFileExtensions = webURLHandlerInfo(
                documentType: ["CFBundleTypeExtensions": ["html", "htm"]]
            )
            let genericURLHandlerInfo = webURLHandlerInfo()

            #expect(MeetingLinkApplicationCatalog.isWebBrowser(infoDictionary: browserInfo))
            #expect(MeetingLinkApplicationCatalog.isWebBrowser(infoDictionary: browserUsingFileExtensions))
            #expect(!MeetingLinkApplicationCatalog.isWebBrowser(infoDictionary: genericURLHandlerInfo))
        }

        @Test
        func chromeApplicationsResolveServiceFromShortcutURL() throws {
            func service(_ shortcutURL: String) -> MeetingLinkService? {
                MeetingLinkApplicationCatalog.chromeApplicationShortcutURL(
                    infoDictionary: ["CrAppModeShortcutURL": shortcutURL]
                ).flatMap(MeetingLinkService.init(conferenceURL:))
            }

            #expect(service("https://meet.google.com/landing?lfhs=2") == .googleMeet)
            #expect(service("https://teams.microsoft.com/v2/?clientType=pwa") == .teams)
            #expect(service("https://calendar.google.com/") == nil)
            #expect(MeetingLinkApplicationCatalog.chromeApplicationShortcutURL(infoDictionary: [:]) == nil)
        }

        @Test
        func chromeAppLaunchesThroughItsBrowserWithTheMeetingURL() throws {
            let meetingURL = try url("https://meet.google.com/abc-defg-hij")
            let userData = FileManager.default.temporaryDirectory.appending(path: "dahlia-chrome-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: userData) }
            try FileManager.default.createDirectory(
                at: userData.appending(path: "Profile 2/Web Applications/Manifest Resources/meetapp"),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(at: userData.appending(path: "Default"), withIntermediateDirectories: true)
            let info: [String: Any] = [
                "CrAppModeShortcutID": "meetapp",
                "CrAppModeUserDataDir": userData.path + "/-/Web Applications/_crx_meetapp",
            ]

            #expect(SystemMeetingLinkWorkspace.chromeAppLaunchArguments(infoDictionary: info, url: meetingURL) == [
                "--user-data-dir=\(userData.path)",
                "--profile-directory=Profile 2",
                "--app-id=meetapp",
                "--app-launch-url-for-shortcuts-menu-item=https://meet.google.com/abc-defg-hij",
            ])
            // インストール先が見つからない shim は、ブラウザーの既定に任せる。
            #expect(SystemMeetingLinkWorkspace.chromeAppInstallation(
                infoDictionary: ["CrAppModeShortcutID": "other", "CrAppModeUserDataDir": userData.path + "/-/x"]
            ) == nil)
            #expect(SystemMeetingLinkWorkspace.chromeAppLaunchArguments(
                infoDictionary: ["CrAppModeShortcutID": "other"],
                url: meetingURL
            ) == ["--app-id=other", "--app-launch-url-for-shortcuts-menu-item=https://meet.google.com/abc-defg-hij"])
            #expect(SystemMeetingLinkWorkspace.chromeAppLaunchArguments(infoDictionary: [:], url: meetingURL) == nil)
        }

        @Test(arguments: [false, true])
        func joinAndRecordOpensMeetingWhenRecordingCannotStart(isListening: Bool) async throws {
            let workspace = TestMeetingLinkWorkspace()
            let opener = MeetingLinkOpener(
                settings: TestSettings(globalTarget: .systemDefault),
                workspace: workspace
            )
            let viewModel = CaptionViewModel(
                availableInputDevicesProvider: { [] },
                defaultInputDeviceIDProvider: { nil }
            )
            viewModel.isListening = isListening
            var recordingStarts = 0
            let coordinator = RecordingCoordinator(
                viewModel: viewModel,
                sidebarViewModel: SidebarViewModel(settings: AppSettings()),
                mainWindowNavigation: MainWindowNavigation(
                    openMainWindow: {},
                    openMainWindowWithoutActivation: {}
                ),
                onRecordingDidStart: { recordingStarts += 1 },
                onRecordingDidStop: {},
                meetingLinkOpener: opener
            )
            let meetingURL = try url("https://meet.google.com/abc")
            let now = Date()
            let event = CalendarEvent(
                id: "event",
                calendarID: "calendar",
                calendarName: "Calendar",
                calendarColorHex: nil,
                platformId: "event",
                title: "Meeting",
                description: "",
                icalUid: nil,
                startDate: now,
                endDate: now.addingTimeInterval(60),
                isAllDay: false,
                conferenceURI: meetingURL
            )

            coordinator.joinCalendarEventAndStartRecording(event)

            #expect(await pollUntil {
                await workspace.attemptedApplications() == [nil]
            })
            #expect(viewModel.isListening == isListening)
            #expect(recordingStarts == 0)
        }

        @Test
        func openingMeetingLinkDoesNotWaitForMainActor() async throws {
            let workspace = TestMeetingLinkWorkspace()
            let opener = MeetingLinkOpener(
                settings: TestSettings(globalTarget: .systemDefault),
                workspace: workspace
            )

            let opening = try MeetingLinkOpeningTaskContext.$isMainActorCaller.withValue(true) {
                try opener.open(url("https://meet.google.com/abc"))
            }

            #expect(await opening.value != nil)
            #expect(await workspace.attemptedApplications() == [nil])
            #expect(await workspace.observedMainActorCallerValues() == [false])
        }

        @Test
        func serviceApplicationOverridesGlobalApplication() async throws {
            let settings = TestSettings(
                globalTarget: .application(bundleIdentifier: "com.google.Chrome"),
                serviceTargets: [.zoom: .application(bundleIdentifier: "us.zoom.xos")]
            )
            let workspace = TestMeetingLinkWorkspace(
                applicationURLs: [
                    "com.google.Chrome": URL(filePath: "/Applications/Google Chrome.app"),
                    "us.zoom.xos": URL(filePath: "/Applications/zoom.us.app"),
                ]
            )
            let opener = MeetingLinkOpener(settings: settings, workspace: workspace)
            let meetingURL = try url("https://zoom.us/j/123")

            #expect(await opener.open(meetingURL).value != nil)
            #expect(await workspace.attemptedApplications() == [URL(filePath: "/Applications/zoom.us.app")])
        }

        @Test
        func unavailableServiceAndGlobalAppsFallBackInOrder() async throws {
            let settings = TestSettings(
                globalTarget: .application(bundleIdentifier: "com.google.Chrome"),
                serviceTargets: [.zoom: .application(bundleIdentifier: "us.zoom.xos")]
            )
            let chromeURL = URL(filePath: "/Applications/Google Chrome.app")
            let workspace = TestMeetingLinkWorkspace(
                applicationURLs: ["com.google.Chrome": chromeURL],
                failedApplicationURLs: [chromeURL]
            )
            let opener = MeetingLinkOpener(settings: settings, workspace: workspace)
            let meetingURL = try url("https://zoom.us/j/123")

            #expect(await opener.open(meetingURL).value != nil)
            #expect(await workspace.resolvedBundleIdentifiers() == ["us.zoom.xos", "com.google.Chrome"])
            #expect(await workspace.attemptedApplications() == [chromeURL, nil])
        }

        @Test
        func failedServiceApplicationFallsBackToGlobalApplication() async throws {
            let settings = TestSettings(
                globalTarget: .application(bundleIdentifier: "com.google.Chrome"),
                serviceTargets: [.zoom: .application(bundleIdentifier: "us.zoom.xos")]
            )
            let zoomURL = URL(filePath: "/Applications/zoom.us.app")
            let chromeURL = URL(filePath: "/Applications/Google Chrome.app")
            let workspace = TestMeetingLinkWorkspace(
                applicationURLs: [
                    "com.google.Chrome": chromeURL,
                    "us.zoom.xos": zoomURL,
                ],
                failedApplicationURLs: [zoomURL]
            )
            let opener = MeetingLinkOpener(settings: settings, workspace: workspace)

            #expect(try await opener.open(url("https://zoom.us/j/123")).value != nil)
            #expect(await workspace.attemptedApplications() == [zoomURL, chromeURL])
        }

        @Test
        func unknownServiceUsesGlobalApplication() async throws {
            let chromeURL = URL(filePath: "/Applications/Google Chrome.app")
            let workspace = TestMeetingLinkWorkspace(
                applicationURLs: ["com.google.Chrome": chromeURL]
            )
            let opener = MeetingLinkOpener(
                settings: TestSettings(globalTarget: .application(bundleIdentifier: "com.google.Chrome")),
                workspace: workspace
            )

            #expect(try await opener.open(url("https://example.com/meeting")).value != nil)
            #expect(await workspace.attemptedApplications() == [chromeURL])
        }

        @Test
        func explicitSystemDefaultSkipsGlobalApplication() async throws {
            let settings = TestSettings(
                globalTarget: .application(bundleIdentifier: "com.google.Chrome"),
                serviceTargets: [.teams: .systemDefault]
            )
            let workspace = TestMeetingLinkWorkspace(
                applicationURLs: ["com.google.Chrome": URL(filePath: "/Applications/Google Chrome.app")]
            )
            let opener = MeetingLinkOpener(settings: settings, workspace: workspace)

            #expect(try await opener.open(url("https://teams.microsoft.com/l/meetup-join/abc")).value != nil)
            #expect(await workspace.attemptedApplications() == [nil])
        }

        private func url(_ string: String) throws -> URL {
            try #require(URL(string: string))
        }

        @MainActor
        private final class TestSettings: MeetingLinkOpenSettingsProviding {
            let defaultMeetingLinkOpenTarget: MeetingLinkOpenTarget
            private let serviceTargets: [MeetingLinkService: MeetingLinkOpenTarget]

            init(
                globalTarget: MeetingLinkOpenTarget,
                serviceTargets: [MeetingLinkService: MeetingLinkOpenTarget] = [:]
            ) {
                self.defaultMeetingLinkOpenTarget = globalTarget
                self.serviceTargets = serviceTargets
            }

            func meetingLinkOpenTarget(for service: MeetingLinkService) -> MeetingLinkOpenTarget {
                serviceTargets[service] ?? .inheritGlobal
            }
        }

        private actor TestMeetingLinkWorkspace: MeetingLinkWorkspaceOpening {
            private let applicationURLs: [String: URL]
            private let failedApplicationURLs: Set<URL>
            private var attempts: [URL?] = []
            private var inheritedMainActorCallerValues: [Bool] = []
            private var resolvedBundleIdentifiersStorage: [String] = []

            init(
                applicationURLs: [String: URL] = [:],
                failedApplicationURLs: Set<URL> = []
            ) {
                self.applicationURLs = applicationURLs
                self.failedApplicationURLs = failedApplicationURLs
            }

            func applicationURL(forBundleIdentifier bundleIdentifier: String) async -> URL? {
                resolvedBundleIdentifiersStorage.append(bundleIdentifier)
                return applicationURLs[bundleIdentifier]
            }

            func open(_: URL, withApplicationAt applicationURL: URL?) async -> String? {
                attempts.append(applicationURL)
                inheritedMainActorCallerValues.append(MeetingLinkOpeningTaskContext.isMainActorCaller)
                guard let applicationURL else { return "default.browser" }
                return failedApplicationURLs.contains(applicationURL) ? nil : applicationURL.lastPathComponent
            }

            func attemptedApplications() -> [URL?] {
                attempts
            }

            func observedMainActorCallerValues() -> [Bool] {
                inheritedMainActorCallerValues
            }

            func resolvedBundleIdentifiers() -> [String] {
                resolvedBundleIdentifiersStorage
            }
        }
    }

    private enum MeetingLinkOpeningTaskContext {
        @TaskLocal static var isMainActorCaller = false
    }

    private func webURLHandlerInfo(documentType: [String: Any]? = nil) -> [String: Any] {
        var info: [String: Any] = [
            "CFBundleURLTypes": [
                ["CFBundleURLSchemes": ["http", "https"]],
            ],
        ]
        if let documentType {
            info["CFBundleDocumentTypes"] = [documentType]
        }
        return info
    }

    private struct UserDefaultsValueSnapshot {
        let key: String
        let value: Any?

        init(key: String) {
            self.key = key
            self.value = UserDefaults.standard.object(forKey: key)
        }

        func restore() {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
#endif
