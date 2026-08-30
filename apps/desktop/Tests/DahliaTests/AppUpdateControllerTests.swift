import Sparkle
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct AppUpdateControllerTests {
        @Test
        func delegatedScheduledUpdatePublishesBadge() {
            let controller = AppUpdateController(shouldStartUpdater: false)

            controller.recordAvailableUpdate(
                version: "1.2.3",
                isHandledByStandardUserDriver: false
            )

            #expect(controller.availableVersion == "1.2.3")
            #expect(controller.isUpdateAvailable)
        }

        @Test
        func standardUpdateDialogPublishesBadge() {
            let controller = AppUpdateController(shouldStartUpdater: false)

            controller.recordAvailableUpdate(
                version: "1.2.3",
                isHandledByStandardUserDriver: true
            )

            #expect(controller.availableVersion == "1.2.3")
            #expect(controller.isUpdateAvailable)
        }

        @Test
        func dismissingUpdateDialogKeepsBadge() {
            let controller = AppUpdateController(shouldStartUpdater: false)
            controller.recordAvailableUpdate(
                version: "1.2.3",
                isHandledByStandardUserDriver: false
            )

            controller.recordUserChoice(.dismiss)

            #expect(controller.availableVersion == "1.2.3")
            #expect(controller.isUpdateAvailable)
        }

        @Test
        func startingInstallationKeepsBadgeUntilRelaunch() {
            let controller = AppUpdateController(shouldStartUpdater: false)
            controller.recordAvailableUpdate(
                version: "1.2.3",
                isHandledByStandardUserDriver: false
            )

            controller.recordUserChoice(.install)

            #expect(controller.availableVersion == "1.2.3")
            #expect(controller.isUpdateAvailable)
        }

        @Test
        func skippingUpdateClearsBadge() {
            let controller = AppUpdateController(shouldStartUpdater: false)
            controller.recordAvailableUpdate(
                version: "1.2.3",
                isHandledByStandardUserDriver: false
            )

            controller.recordUserChoice(.skip)

            #expect(controller.availableVersion == nil)
            #expect(!controller.isUpdateAvailable)
        }

        @Test
        func noUpdateResultClearsStaleBadge() {
            let controller = AppUpdateController(shouldStartUpdater: false)
            controller.recordAvailableUpdate(
                version: "1.2.3",
                isHandledByStandardUserDriver: false
            )

            controller.updaterDidNotFindUpdate(
                controller.updater,
                error: NSError(domain: SUSparkleErrorDomain, code: 0)
            )

            #expect(controller.availableVersion == nil)
            #expect(!controller.isUpdateAvailable)
        }
    }
#endif
