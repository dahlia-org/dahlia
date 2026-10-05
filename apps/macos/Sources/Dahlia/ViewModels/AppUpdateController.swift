import Observation
import Sparkle

/// Sparkle's scheduled driver keeps the appcast item it found until the user answers it, which blocks later checks
/// and makes the update dialog offer a stale version. Dahlia therefore leaves Sparkle's scheduler disabled, probes the
/// feed without UI for the badge, and lets the badge start a fresh user-initiated check.
@MainActor
@Observable
final class AppUpdateController: NSObject, @MainActor SPUUpdaterDelegate {
    private static let updateInformationCheckInterval: Duration = .seconds(60 * 60)

    private(set) var availableVersion: String?

    @ObservationIgnored private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    var updater: SPUUpdater {
        updaterController.updater
    }

    var isUpdateAvailable: Bool {
        availableVersion != nil
    }

    init(shouldStartUpdater: Bool = AppUpdatePolicy.shouldStartUpdater()) {
        super.init()

        if shouldStartUpdater {
            updaterController.startUpdater()
            Task { [weak self] in
                while !Task.isCancelled {
                    self?.checkForUpdateInformation()
                    try? await Task.sleep(for: Self.updateInformationCheckInterval)
                }
            }
        }
    }

    func showUpdateDialog() {
        updater.checkForUpdates()
    }

    private func checkForUpdateInformation() {
        guard !updater.sessionInProgress else {
            return
        }
        updater.checkForUpdateInformation()
    }

    func updater(_: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        recordAvailableUpdate(version: item.displayVersionString)
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

    func recordAvailableUpdate(version: String) {
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
