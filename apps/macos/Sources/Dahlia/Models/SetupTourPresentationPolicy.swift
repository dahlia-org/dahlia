import Foundation

enum SetupTourPresentationPolicy {
    static let userDefaultsKey = "setupTourPresentationVersion"
    static let progressStepUserDefaultsKey = "setupTourProgressStep"
    static let providerUserDefaultsKey = "setupTourProvider"
    static let databricksProfileUserDefaultsKey = "setupTourDatabricksProfile"
    static let accountConnectionIDUserDefaultsKey = "setupTourAccountConnectionID"
    static let databricksConnectionIDUserDefaultsKey = "setupTourDatabricksConnectionID"
    static let accountSelectionConfirmedUserDefaultsKey = "setupTourAccountSelectionConfirmed"
    /// Marks progress saved after the model provider step moved to right after account selection.
    static let modelProviderFirstUserDefaultsKey = "setupTourModelProviderFirst"
    static let currentVersion = 1

    static func shouldPresentAutomatically(
        storedVersion: Int,
        hasLoadedWorkspaces: Bool,
        hasRegisteredWorkspaces: Bool,
        hasSavedProgress: Bool = false
    ) -> Bool {
        // The completion flag lives in UserDefaults, which can outlive or be shared beyond the database.
        hasLoadedWorkspaces && (!hasRegisteredWorkspaces || (hasSavedProgress && storedVersion < currentVersion))
    }

    static func markCompleted(in defaults: UserDefaults = .standard) {
        defaults.set(currentVersion, forKey: userDefaultsKey)
        clearProgress(in: defaults)
    }

    static func restoredStep(in defaults: UserDefaults = .standard) -> SetupTourStep {
        guard defaults.object(forKey: progressStepUserDefaultsKey) != nil else { return .account }
        return SetupTourStep(rawValue: defaults.integer(forKey: progressStepUserDefaultsKey)) ?? .account
    }

    static func saveProgress(
        step: SetupTourStep,
        accountConnectionID: UUID? = nil,
        databricksConnectionID: UUID? = nil,
        isAccountSelectionConfirmed: Bool = false,
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(step.rawValue, forKey: progressStepUserDefaultsKey)
        defaults.set(accountConnectionID?.uuidString, forKey: accountConnectionIDUserDefaultsKey)
        defaults.set(databricksConnectionID?.uuidString, forKey: databricksConnectionIDUserDefaultsKey)
        defaults.set(isAccountSelectionConfirmed, forKey: accountSelectionConfirmedUserDefaultsKey)
        defaults.set(true, forKey: modelProviderFirstUserDefaultsKey)
    }

    /// Progress saved by v0.29.0 or earlier, which asked for model providers after permissions.
    static func hasProgressBeforeModelProviderMoved(in defaults: UserDefaults = .standard) -> Bool {
        hasSavedProgress(in: defaults) && defaults.object(forKey: modelProviderFirstUserDefaultsKey) == nil
    }

    static func restoredAccountConnectionID(in defaults: UserDefaults = .standard) -> UUID? {
        defaults.string(forKey: accountConnectionIDUserDefaultsKey).flatMap(UUID.init(uuidString:))
    }

    static func restoredDatabricksConnectionID(in defaults: UserDefaults = .standard) -> UUID? {
        defaults.string(forKey: databricksConnectionIDUserDefaultsKey).flatMap(UUID.init(uuidString:))
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

    static func hasSavedProgress(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: progressStepUserDefaultsKey) != nil
    }

    private static func clearProgress(in defaults: UserDefaults) {
        defaults.removeObject(forKey: progressStepUserDefaultsKey)
        defaults.removeObject(forKey: providerUserDefaultsKey)
        defaults.removeObject(forKey: databricksProfileUserDefaultsKey)
        defaults.removeObject(forKey: accountConnectionIDUserDefaultsKey)
        defaults.removeObject(forKey: databricksConnectionIDUserDefaultsKey)
        defaults.removeObject(forKey: accountSelectionConfirmedUserDefaultsKey)
        defaults.removeObject(forKey: modelProviderFirstUserDefaultsKey)
    }
}
