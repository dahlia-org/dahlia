import Foundation
import Observation

@MainActor
@Observable
final class DatabricksAccountController {
    private(set) var profiles: [DatabricksCLIClient.Profile] = []
    private(set) var isLoadingProfiles = false
    private(set) var isSigningIn = false
    private(set) var isApplyingConfiguration = false
    private(set) var isConfigured = false
    private(set) var configuredProfileName: String?
    private(set) var isCLIAvailable: Bool?
    private(set) var errorMessage: String?

    private var allProfiles: [DatabricksCLIClient.Profile] = []
    private let client: DatabricksCLIClient
    private let cliInstaller: any DatabricksCLIInstalling
    private let configurationManager: CodexConfigurationManager
    private let service: CodexAppServerService
    private let configurationStore: any CodexAccountConfigurationStoring

    init(
        client: DatabricksCLIClient = DatabricksCLIClient(),
        cliInstaller: any DatabricksCLIInstalling = DatabricksCLIInstaller(),
        configurationManager: CodexConfigurationManager = CodexConfigurationManager(),
        service: CodexAppServerService = .shared,
        configurationStore: any CodexAccountConfigurationStoring = AppSettings.shared
    ) {
        self.client = client
        self.cliInstaller = cliInstaller
        self.configurationManager = configurationManager
        self.service = service
        self.configurationStore = configurationStore
    }

    var isBusy: Bool {
        isLoadingProfiles || isSigningIn || isApplyingConfiguration
    }

    func prepare(
        profileName: String,
        restoreProviderSelectionOnCancellation: Bool = true
    ) async -> String? {
        let previousProfileName = configuredDatabricksProfileName()
        let hasSelectedProfile = profileName.nilIfBlank != nil
        let fallbackProfileName = hasSelectedProfile ? previousProfileName : nil
        await loadProfiles()
        guard !Task.isCancelled else { return fallbackProfileName }
        guard errorMessage == nil else { return fallbackProfileName }
        guard isCLIAvailable == true else { return fallbackProfileName }
        guard hasSelectedProfile else { return nil }

        guard profiles.contains(where: { $0.name == profileName }) else { return "" }
        let restorableProfileName = previousProfileName.flatMap { previousProfileName in
            profiles.contains { $0.name == previousProfileName } ? previousProfileName : nil
        }
        await apply(
            profileName: profileName,
            restoreProviderSelectionOnCancellation: restoreProviderSelectionOnCancellation
        )
        guard isConfigured, configuredProfileName == profileName else {
            return restorableProfileName
        }
        return nil
    }

    func signIn(
        workspaceURL: String,
        profileName: String,
        restoreProviderSelectionOnCancellation: Bool = true
    ) async -> String? {
        guard !isBusy else { return nil }
        guard let profileName = profileName.nilIfBlank else {
            errorMessage = L10n.databricksProfileRequired
            return nil
        }
        isSigningIn = true
        isConfigured = false
        configuredProfileName = nil
        errorMessage = nil
        var attemptedProfileName: String?
        defer {
            isSigningIn = false
            isApplyingConfiguration = false
        }

        do {
            let workspaceURL = try configurationManager.normalizedDatabricksWorkspaceURL(workspaceURL)
            try Task.checkCancellation()
            allProfiles = try await client.allProfiles()
            isCLIAvailable = true
            if let existingProfile = allProfiles.first(where: { $0.name == profileName }),
               !isOAuthProfile(existingProfile, for: workspaceURL) {
                throw DatabricksCLIError.profileAlreadyExists(name: profileName)
            }
            attemptedProfileName = profileName
            await service.markProviderAuthenticationReloadRequired()
            try await client.signIn(workspaceURL: workspaceURL, profileName: profileName)
            try Task.checkCancellation()
            let signedInProfiles = try await client.allProfiles()
            updateProfiles(signedInProfiles)
            guard let profile = profile(named: profileName),
                  isOAuthProfile(profile, for: workspaceURL) else {
                throw DatabricksCLIError.invalidProfilesResponse
            }
            isSigningIn = false
            isApplyingConfiguration = true
            try await configure(profile: profile, browserLoginCompleted: true)
            return profileName
        } catch is CancellationError {
            restoreConfiguredStateFromStore(
                excluding: attemptedProfileName,
                restoreProviderSelection: restoreProviderSelectionOnCancellation
            )
            return nil
        } catch DatabricksCLIError.cliNotInstalled {
            isCLIAvailable = false
            updateProfiles([])
            restoreConfiguredStateFromStore(excluding: attemptedProfileName)
            return nil
        } catch {
            restoreConfiguredStateFromStore(excluding: attemptedProfileName)
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func installCLIInTerminal() -> DatabricksCLIInstallationResult {
        cliInstaller.installInTerminal()
    }

    func restoreSelectedProvider() {
        if let provider = configurationStore.codexAccountConfigurationSnapshot.provider {
            configurationStore.selectCodexAccountProvider(provider)
        }
    }

    func profile(named name: String) -> DatabricksCLIClient.Profile? {
        profiles.first { $0.name == name }
    }

    private func loadProfiles() async {
        isLoadingProfiles = true
        isConfigured = false
        configuredProfileName = nil
        errorMessage = nil
        defer { isLoadingProfiles = false }

        do {
            let loadedProfiles = try await client.allProfiles()
            updateProfiles(loadedProfiles)
            isCLIAvailable = true
        } catch is CancellationError {
            // SwiftUI cancels this operation when the settings screen disappears.
        } catch DatabricksCLIError.cliNotInstalled {
            updateProfiles([])
            isCLIAvailable = false
        } catch {
            updateProfiles([])
            isCLIAvailable = true
            errorMessage = error.localizedDescription
        }
    }

    private func apply(
        profileName: String,
        restoreProviderSelectionOnCancellation: Bool
    ) async {
        guard let profile = profile(named: profileName) else {
            errorMessage = L10n.databricksProfileRequired
            return
        }

        isApplyingConfiguration = true
        isConfigured = false
        errorMessage = nil
        defer { isApplyingConfiguration = false }

        do {
            try await configure(profile: profile)
        } catch is CancellationError {
            restoreConfiguredStateFromStore(
                excluding: profile.name,
                restoreProviderSelection: restoreProviderSelectionOnCancellation
            )
            // A newer profile selection superseded this configuration attempt.
        } catch {
            restoreConfiguredStateFromStore(excluding: profile.name)
            errorMessage = error.localizedDescription
        }
    }

    private func configure(
        profile: DatabricksCLIClient.Profile,
        browserLoginCompleted: Bool = false
    ) async throws {
        try Task.checkCancellation()
        try configurationManager.validateDatabricks(profile: profile)
        let authenticationResult = try await client.ensureAuthenticated(
            profileName: profile.name,
            onBrowserLoginRequired: {
                await service.markProviderAuthenticationReloadRequired()
            }
        )
        try Task.checkCancellation()
        let previousAccountConfiguration = configurationStore.codexAccountConfigurationSnapshot
        let previousConfiguration = try await configurationManager.configurationData()
        configurationStore.invalidateCodexAccountConfiguration()
        do {
            let configurationChanged = try await configurationManager.configureDatabricks(profile: profile)
            if configurationChanged || browserLoginCompleted || authenticationResult == .browserLoginCompleted {
                try await service.reloadConfiguration()
            }
            try Task.checkCancellation()
            _ = try await service.models(
                forceRefresh: true,
                bypassConfigurationCheck: true,
                bypassProviderAuthenticationPreparation: true
            )
            try Task.checkCancellation()
        } catch {
            try await configurationManager.restoreConfiguration(previousConfiguration)
            await service.markProviderAuthenticationReloadRequired()
            try? await service.reloadConfiguration()
            configurationStore.restoreCodexAccountConfiguration(previousAccountConfiguration)
            throw error
        }
        configurationStore.markCodexAccountConfigurationCurrent(
            provider: .databricks,
            databricksProfile: profile.name
        )
        configurationStore.selectCodexAccountProvider(.databricks)
        isConfigured = true
        configuredProfileName = profile.name
    }

    private func updateProfiles(_ profiles: [DatabricksCLIClient.Profile]) {
        allProfiles = profiles
        self.profiles = profiles.filter(\.usesOAuthU2M)
    }

    private func isOAuthProfile(_ profile: DatabricksCLIClient.Profile, for workspaceURL: URL) -> Bool {
        guard profile.usesOAuthU2M,
              let profileWorkspaceURL = try? configurationManager.normalizedDatabricksWorkspaceURL(profile.host)
        else {
            return false
        }
        return profileWorkspaceURL == workspaceURL
    }

    private func configuredDatabricksProfileName() -> String? {
        let snapshot = configurationStore.codexAccountConfigurationSnapshot
        guard snapshot.provider == .databricks else { return nil }
        return snapshot.databricksProfile.nilIfBlank
    }

    private func restoreConfiguredStateFromStore(
        excluding attemptedProfileName: String?,
        restoreProviderSelection: Bool = false
    ) {
        let snapshot = configurationStore.codexAccountConfigurationSnapshot
        configurationStore.restoreCodexAccountConfiguration(snapshot)
        if restoreProviderSelection, let provider = snapshot.provider {
            configurationStore.selectCodexAccountProvider(provider)
        }
        configuredProfileName = snapshot.provider == .databricks ? snapshot.databricksProfile.nilIfBlank : nil
        configuredProfileName = configuredProfileName.flatMap { profileName in
            profiles.contains { $0.name == profileName } ? profileName : nil
        }
        if configuredProfileName == attemptedProfileName {
            configuredProfileName = nil
        }
        isConfigured = configuredProfileName != nil
    }
}
