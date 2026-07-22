@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct PermissionGuideTests {
        @Test
        func refreshReadsEveryPermissionStatus() {
            let provider = StubAppPermissionProvider(statuses: [
                .screenAndSystemAudio: .granted,
                .microphone: .denied,
                .calendar: .restricted,
            ])
            let model = PermissionGuideModel(provider: provider, settingsOpener: StubSystemSettingsOpener())

            model.refresh()

            #expect(model.status(for: .screenAndSystemAudio) == .granted)
            #expect(model.status(for: .microphone) == .denied)
            #expect(model.status(for: .calendar) == .restricted)
            #expect(provider.statusRequests == AppPermission.allCases + AppPermission.allCases)
        }

        @Test
        func notDeterminedPermissionRequestsAccess() async {
            let provider = StubAppPermissionProvider(
                statuses: [.microphone: .notDetermined],
                requestedStatuses: [.microphone: .granted]
            )
            let opener = StubSystemSettingsOpener()
            let model = PermissionGuideModel(provider: provider, settingsOpener: opener)

            await model.performPrimaryAction(for: .microphone)

            #expect(provider.permissionRequests == [.microphone])
            #expect(opener.openedPermissions.isEmpty)
            #expect(model.status(for: .microphone) == .granted)
        }

        @Test
        func resolvedPermissionOpensSystemSettings() async {
            let provider = StubAppPermissionProvider(statuses: [.calendar: .denied])
            let opener = StubSystemSettingsOpener()
            let model = PermissionGuideModel(provider: provider, settingsOpener: opener)
            model.refresh()

            await model.performPrimaryAction(for: .calendar)

            #expect(provider.permissionRequests.isEmpty)
            #expect(opener.openedPermissions == [.calendar])
        }

        @Test
        func failedSettingsOpenIsVisibleToTheView() {
            let opener = StubSystemSettingsOpener(result: false)
            let model = PermissionGuideModel(
                provider: StubAppPermissionProvider(),
                settingsOpener: opener
            )

            model.openSystemSettings(for: .screenAndSystemAudio)

            #expect(model.settingsOpenFailed)
        }

        @Test
        func firstLaunchGuideUsesVersionedOneTimePresentation() {
            #expect(PermissionGuidePresentationPolicy.shouldPresent(storedVersion: 0))
            #expect(!PermissionGuidePresentationPolicy.shouldPresent(
                storedVersion: PermissionGuidePresentationPolicy.currentVersion
            ))
        }

        @Test
        func systemSettingsRoutesIncludeSpecificAndFallbackURLs() {
            let expectedAnchors: [AppPermission: String] = [
                .screenAndSystemAudio: "Privacy_ScreenCapture",
                .microphone: "Privacy_Microphone",
                .calendar: "Privacy_Calendars",
            ]

            for (permission, expectedAnchor) in expectedAnchors {
                let urls = SystemSettingsOpener.urls(for: permission)
                #expect(urls.count == 2)
                #expect(urls[0].absoluteString.contains(expectedAnchor))
                #expect(urls[1].absoluteString == "x-apple.systempreferences:com.apple.preference.security")
            }
        }
    }

    @MainActor
    private final class StubAppPermissionProvider: AppPermissionProviding {
        var statuses: [AppPermission: AppPermissionStatus]
        var requestedStatuses: [AppPermission: AppPermissionStatus]
        private(set) var statusRequests: [AppPermission] = []
        private(set) var permissionRequests: [AppPermission] = []

        init(
            statuses: [AppPermission: AppPermissionStatus] = [:],
            requestedStatuses: [AppPermission: AppPermissionStatus] = [:]
        ) {
            self.statuses = statuses
            self.requestedStatuses = requestedStatuses
        }

        func status(for permission: AppPermission) -> AppPermissionStatus {
            statusRequests.append(permission)
            return statuses[permission] ?? .notDetermined
        }

        func request(_ permission: AppPermission) async -> AppPermissionStatus {
            permissionRequests.append(permission)
            return requestedStatuses[permission] ?? .denied
        }
    }

    @MainActor
    private final class StubSystemSettingsOpener: SystemSettingsOpening {
        private let result: Bool
        private(set) var openedPermissions: [AppPermission] = []

        init(result: Bool = true) {
            self.result = result
        }

        func openSettings(for permission: AppPermission) -> Bool {
            openedPermissions.append(permission)
            return result
        }
    }
#endif
