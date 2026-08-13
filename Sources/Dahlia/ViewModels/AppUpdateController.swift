import Observation
import Sparkle

@MainActor
@Observable
final class AppUpdateController: NSObject, @MainActor SPUStandardUserDriverDelegate {
    private(set) var availableVersion: String?

    @ObservationIgnored private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
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

    func standardUserDriverDidReceiveUserAttention(forUpdate _: SUAppcastItem) {
        availableVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
    }

    func recordAvailableUpdate(version: String, isHandledByStandardUserDriver: Bool) {
        guard !isHandledByStandardUserDriver else { return }
        availableVersion = version
    }
}
