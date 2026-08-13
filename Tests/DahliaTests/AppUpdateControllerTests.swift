@testable import Dahlia
import Sparkle

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
        func standardUpdateDialogDoesNotPublishBadge() {
            let controller = AppUpdateController(shouldStartUpdater: false)

            controller.recordAvailableUpdate(
                version: "1.2.3",
                isHandledByStandardUserDriver: true
            )

            #expect(controller.availableVersion == nil)
            #expect(!controller.isUpdateAvailable)
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

        @Test(arguments: [SPUUserUpdateChoice.install, .skip])
        func committedUpdateChoiceClearsBadge(choice: SPUUserUpdateChoice) {
            let controller = AppUpdateController(shouldStartUpdater: false)
            controller.recordAvailableUpdate(
                version: "1.2.3",
                isHandledByStandardUserDriver: false
            )

            controller.recordUserChoice(choice)

            #expect(controller.availableVersion == nil)
            #expect(!controller.isUpdateAvailable)
        }
    }
#endif
