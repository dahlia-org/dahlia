import Foundation

enum SetupTourPresentationPolicy {
    static let userDefaultsKey = "setupTourPresentationVersion"
    static let progressStepUserDefaultsKey = "setupTourProgressStep"
    static let vaultPathUserDefaultsKey = "setupTourVaultPath"
    static let vaultNameUserDefaultsKey = "setupTourVaultName"
    static let vaultConfirmedUserDefaultsKey = "setupTourVaultConfirmed"
    static let providerUserDefaultsKey = "setupTourProvider"
    static let databricksProfileUserDefaultsKey = "setupTourDatabricksProfile"
    static let accountConnectionIDUserDefaultsKey = "setupTourAccountConnectionID"
    static let accountSelectionConfirmedUserDefaultsKey = "setupTourAccountSelectionConfirmed"
    static let currentVersion = 1

    static func shouldPresentAutomatically(
        storedVersion: Int,
        hasLoadedVaults: Bool,
        hasRegisteredVaults: Bool,
        hasSavedProgress: Bool = false
    ) -> Bool {
        hasLoadedVaults && (!hasRegisteredVaults || hasSavedProgress) && storedVersion < currentVersion
    }

    static func markCompleted(in defaults: UserDefaults = .standard) {
        defaults.set(currentVersion, forKey: userDefaultsKey)
        clearProgress(in: defaults)
    }

    static func restoredStep(in defaults: UserDefaults = .standard) -> SetupTourStep {
        guard defaults.object(forKey: progressStepUserDefaultsKey) != nil else { return .account }
        return SetupTourStep(rawValue: defaults.integer(forKey: progressStepUserDefaultsKey)) ?? .account
    }

    static func restoredVaultURL(in defaults: UserDefaults = .standard) -> URL? {
        guard let path = defaults.string(forKey: vaultPathUserDefaultsKey)?.nilIfBlank else { return nil }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    static func saveProgress(
        step: SetupTourStep,
        vaultURL: URL,
        vaultName: String? = nil,
        isVaultConfirmed: Bool,
        accountConnectionID: UUID? = nil,
        isAccountSelectionConfirmed: Bool = false,
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(step.rawValue, forKey: progressStepUserDefaultsKey)
        defaults.set(vaultURL.path, forKey: vaultPathUserDefaultsKey)
        defaults.set(vaultName, forKey: vaultNameUserDefaultsKey)
        defaults.set(isVaultConfirmed, forKey: vaultConfirmedUserDefaultsKey)
        defaults.set(accountConnectionID?.uuidString, forKey: accountConnectionIDUserDefaultsKey)
        defaults.set(isAccountSelectionConfirmed, forKey: accountSelectionConfirmedUserDefaultsKey)
    }

    static func restoredAccountConnectionID(in defaults: UserDefaults = .standard) -> UUID? {
        defaults.string(forKey: accountConnectionIDUserDefaultsKey).flatMap(UUID.init(uuidString:))
    }

    static func restoredVaultName(in defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: vaultNameUserDefaultsKey)?.nilIfBlank
    }

    static func isAccountSelectionConfirmed(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: accountSelectionConfirmedUserDefaultsKey)
    }

    static func saveProviderDraft(
        provider: AIAccountProvider,
        databricksProfile: String,
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(provider.rawValue, forKey: providerUserDefaultsKey)
        defaults.set(databricksProfile, forKey: databricksProfileUserDefaultsKey)
    }

    static func restoredProvider(in defaults: UserDefaults = .standard) -> AIAccountProvider? {
        defaults.string(forKey: providerUserDefaultsKey).flatMap(AIAccountProvider.init(rawValue:))
    }

    static func restoredDatabricksProfile(in defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: databricksProfileUserDefaultsKey) ?? ""
    }

    static func isRestoredVaultConfirmed(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: vaultConfirmedUserDefaultsKey)
    }

    static func hasSavedProgress(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: progressStepUserDefaultsKey) != nil
    }

    private static func clearProgress(in defaults: UserDefaults) {
        defaults.removeObject(forKey: progressStepUserDefaultsKey)
        defaults.removeObject(forKey: vaultPathUserDefaultsKey)
        defaults.removeObject(forKey: vaultNameUserDefaultsKey)
        defaults.removeObject(forKey: vaultConfirmedUserDefaultsKey)
        defaults.removeObject(forKey: providerUserDefaultsKey)
        defaults.removeObject(forKey: databricksProfileUserDefaultsKey)
        defaults.removeObject(forKey: accountConnectionIDUserDefaultsKey)
        defaults.removeObject(forKey: accountSelectionConfirmedUserDefaultsKey)
    }
}
