import Foundation

enum SetupTourPresentationPolicy {
    static let userDefaultsKey = "setupTourPresentationVersion"
    static let progressStepUserDefaultsKey = "setupTourProgressStep"
    static let workspacePathUserDefaultsKey = "setupTourWorkspacePath"
    static let workspaceNameUserDefaultsKey = "setupTourWorkspaceName"
    static let workspaceConfirmedUserDefaultsKey = "setupTourWorkspaceConfirmed"
    static let providerUserDefaultsKey = "setupTourProvider"
    static let databricksProfileUserDefaultsKey = "setupTourDatabricksProfile"
    static let accountConnectionIDUserDefaultsKey = "setupTourAccountConnectionID"
    static let accountSelectionConfirmedUserDefaultsKey = "setupTourAccountSelectionConfirmed"
    static let currentVersion = 1

    static func shouldPresentAutomatically(
        storedVersion: Int,
        hasLoadedWorkspaces: Bool,
        hasRegisteredWorkspaces: Bool,
        hasSavedProgress: Bool = false
    ) -> Bool {
        hasLoadedWorkspaces && (!hasRegisteredWorkspaces || hasSavedProgress) && storedVersion < currentVersion
    }

    static func markCompleted(in defaults: UserDefaults = .standard) {
        defaults.set(currentVersion, forKey: userDefaultsKey)
        clearProgress(in: defaults)
    }

    static func restoredStep(in defaults: UserDefaults = .standard) -> SetupTourStep {
        guard defaults.object(forKey: progressStepUserDefaultsKey) != nil else { return .account }
        return SetupTourStep(rawValue: defaults.integer(forKey: progressStepUserDefaultsKey)) ?? .account
    }

    static func restoredWorkspaceURL(in defaults: UserDefaults = .standard) -> URL? {
        guard let path = defaults.string(forKey: workspacePathUserDefaultsKey)?.nilIfBlank else { return nil }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    static func saveProgress(
        step: SetupTourStep,
        workspaceURL: URL,
        workspaceName: String? = nil,
        isWorkspaceConfirmed: Bool,
        accountConnectionID: UUID? = nil,
        isAccountSelectionConfirmed: Bool = false,
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(step.rawValue, forKey: progressStepUserDefaultsKey)
        defaults.set(workspaceURL.path, forKey: workspacePathUserDefaultsKey)
        defaults.set(workspaceName, forKey: workspaceNameUserDefaultsKey)
        defaults.set(isWorkspaceConfirmed, forKey: workspaceConfirmedUserDefaultsKey)
        defaults.set(accountConnectionID?.uuidString, forKey: accountConnectionIDUserDefaultsKey)
        defaults.set(isAccountSelectionConfirmed, forKey: accountSelectionConfirmedUserDefaultsKey)
    }

    static func restoredAccountConnectionID(in defaults: UserDefaults = .standard) -> UUID? {
        defaults.string(forKey: accountConnectionIDUserDefaultsKey).flatMap(UUID.init(uuidString:))
    }

    static func restoredWorkspaceName(in defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: workspaceNameUserDefaultsKey)?.nilIfBlank
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

    static func isRestoredWorkspaceConfirmed(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: workspaceConfirmedUserDefaultsKey)
    }

    static func hasSavedProgress(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: progressStepUserDefaultsKey) != nil
    }

    private static func clearProgress(in defaults: UserDefaults) {
        defaults.removeObject(forKey: progressStepUserDefaultsKey)
        defaults.removeObject(forKey: workspacePathUserDefaultsKey)
        defaults.removeObject(forKey: workspaceNameUserDefaultsKey)
        defaults.removeObject(forKey: workspaceConfirmedUserDefaultsKey)
        defaults.removeObject(forKey: providerUserDefaultsKey)
        defaults.removeObject(forKey: databricksProfileUserDefaultsKey)
        defaults.removeObject(forKey: accountConnectionIDUserDefaultsKey)
        defaults.removeObject(forKey: accountSelectionConfirmedUserDefaultsKey)
    }
}
