import Observation

@MainActor
@Observable
final class PermissionGuideModel {
    private(set) var statuses: [AppPermission: AppPermissionStatus]
    private(set) var requestingPermission: AppPermission?
    var settingsOpenFailed = false

    private let provider: any AppPermissionProviding
    private let settingsOpener: any SystemSettingsOpening

    init(
        provider: any AppPermissionProviding = SystemAppPermissionProvider(),
        settingsOpener: any SystemSettingsOpening = SystemSettingsOpener()
    ) {
        self.provider = provider
        self.settingsOpener = settingsOpener
        statuses = Dictionary(uniqueKeysWithValues: AppPermission.allCases.map { ($0, provider.status(for: $0)) })
    }

    func status(for permission: AppPermission) -> AppPermissionStatus {
        statuses[permission] ?? .notDetermined
    }

    func refresh() {
        for permission in AppPermission.allCases {
            statuses[permission] = provider.status(for: permission)
        }
    }

    func performPrimaryAction(for permission: AppPermission) async {
        guard requestingPermission == nil else { return }
        guard [.notDetermined, .requiresReview].contains(status(for: permission)) else {
            openSystemSettings(for: permission)
            return
        }

        requestingPermission = permission
        statuses[permission] = await provider.request(permission)
        requestingPermission = nil
    }

    func openSystemSettings(for permission: AppPermission) {
        settingsOpenFailed = !settingsOpener.openSettings(for: permission)
    }
}
