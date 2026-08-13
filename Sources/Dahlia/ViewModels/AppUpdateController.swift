import Observation
import Sparkle

@MainActor
@Observable
final class AppUpdateController: NSObject, @MainActor SPUStandardUserDriverDelegate, @MainActor SPUUpdaterDelegate {
    private(set) var availableVersion: String?

    @ObservationIgnored private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: self
    )

    var updater: SPUUpdater {
        updaterController.updater
    }

    var isUpdateAvailable: Bool {
        availableVersion != nil
    }

    var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    init(shouldStartUpdater: Bool = AppUpdatePolicy.shouldStartUpdater()) {
        super.init()

        if shouldStartUpdater {
            updaterController.startUpdater()
        }
    }

    func showUpdateDialog() {
        updater.checkForUpdates()
    }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _: SUAppcastItem,
        andInImmediateFocus _: Bool
    ) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state _: SPUUserUpdateState
    ) {
        recordAvailableUpdate(
            version: update.displayVersionString,
            isHandledByStandardUserDriver: handleShowingUpdate
        )
    }

    func updater(
        _: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate _: SUAppcastItem,
        state _: SPUUserUpdateState
    ) {
        recordUserChoice(choice)
    }

    func updaterDidNotFindUpdate(_: SPUUpdater, error _: Error) {
        availableVersion = nil
    }

    func recordAvailableUpdate(version: String, isHandledByStandardUserDriver _: Bool) {
        availableVersion = version
    }

    func recordUserChoice(_ choice: SPUUserUpdateChoice) {
        switch choice {
        case .skip:
            availableVersion = nil
        case .install, .dismiss:
            break
        @unknown default:
            break
        }
    }
}
