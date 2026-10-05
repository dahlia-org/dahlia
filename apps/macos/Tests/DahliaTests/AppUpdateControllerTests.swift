import Sparkle
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct AppUpdateControllerTests {
        @Test
        func foundUpdatePublishesBadge() {
            let controller = AppUpdateController(shouldStartUpdater: false)

            controller.recordAvailableUpdate(version: "1.2.3")

            #expect(controller.availableVersion == "1.2.3")
            #expect(controller.isUpdateAvailable)
        }

        @Test
        func laterFoundUpdateReplacesBadgeVersion() {
            let controller = AppUpdateController(shouldStartUpdater: false)
            controller.recordAvailableUpdate(version: "1.2.3")

            controller.recordAvailableUpdate(version: "1.2.5")

            #expect(controller.availableVersion == "1.2.5")
        }

        @Test
        func dismissingUpdateDialogKeepsBadge() {
            let controller = AppUpdateController(shouldStartUpdater: false)
            controller.recordAvailableUpdate(version: "1.2.3")

            controller.recordUserChoice(.dismiss)

            #expect(controller.availableVersion == "1.2.3")
            #expect(controller.isUpdateAvailable)
        }

        @Test
        func startingInstallationKeepsBadgeUntilRelaunch() {
            let controller = AppUpdateController(shouldStartUpdater: false)
            controller.recordAvailableUpdate(version: "1.2.3")

            controller.recordUserChoice(.install)

            #expect(controller.availableVersion == "1.2.3")
            #expect(controller.isUpdateAvailable)
        }

        @Test
        func skippingUpdateClearsBadge() {
            let controller = AppUpdateController(shouldStartUpdater: false)
            controller.recordAvailableUpdate(version: "1.2.3")

            controller.recordUserChoice(.skip)

            #expect(controller.availableVersion == nil)
            #expect(!controller.isUpdateAvailable)
        }

        @Test
        func noUpdateResultClearsStaleBadge() {
            let controller = AppUpdateController(shouldStartUpdater: false)
            controller.recordAvailableUpdate(version: "1.2.3")

            controller.updaterDidNotFindUpdate(
                controller.updater,
                error: NSError(domain: SUSparkleErrorDomain, code: 0)
            )

            #expect(controller.availableVersion == nil)
            #expect(!controller.isUpdateAvailable)
        }

        @Test
        func sparkleSchedulerStaysDisabled() throws {
            let infoPlistURL = URL(filePath: #filePath)
                .deletingLastPathComponent()
                .appending(path: "../../../../Resources/Info.plist")
                .standardized
            let infoPlist = try #require(NSDictionary(contentsOf: infoPlistURL))

            #expect(infoPlist["SUEnableAutomaticChecks"] as? Bool == false)
            #expect(infoPlist["SUScheduledCheckInterval"] == nil)
        }
    }
#endif
