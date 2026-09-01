import Foundation
import Observation

@MainActor
@Observable
final class DatabricksAccountController {
    private(set) var profiles: [DatabricksCLIClient.Profile] = []
    private(set) var isLoadingProfiles = false
    private(set) var isSigningIn = false
    private(set) var isConfigured = false
    private(set) var configuredProfileName: String?
    private(set) var isCLIAvailable: Bool?
    private(set) var errorMessage: String?

    private var allProfiles: [DatabricksCLIClient.Profile] = []
    private let client: DatabricksCLIClient
    private let cliInstaller: any DatabricksCLIInstalling
    private let configurationManager: CodexConfigurationManager

    init(
        client: DatabricksCLIClient = DatabricksCLIClient(),
        cliInstaller: any DatabricksCLIInstalling = DatabricksCLIInstaller(),
        configurationManager: CodexConfigurationManager = CodexConfigurationManager()
    ) {
        self.client = client
        self.cliInstaller = cliInstaller
        self.configurationManager = configurationManager
    }

    var isBusy: Bool {
        isLoadingProfiles || isSigningIn
    }

    func prepare(profileName: String) async -> String? {
        let hasSelectedProfile = profileName.nilIfBlank != nil
        await loadProfiles()
        guard !Task.isCancelled, errorMessage == nil, isCLIAvailable == true else { return nil }
        guard hasSelectedProfile else { return nil }

        guard profiles.contains(where: { $0.name == profileName }) else { return "" }
        isConfigured = true
        configuredProfileName = profileName
        return nil
    }

    func signIn(workspaceURL: String, profileName: String) async -> String? {
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
            try await client.signIn(workspaceURL: workspaceURL, profileName: profileName)
            try Task.checkCancellation()
            let signedInProfiles = try await client.allProfiles()
            updateProfiles(signedInProfiles)
            guard let profile = profile(named: profileName),
                  isOAuthProfile(profile, for: workspaceURL) else {
                throw DatabricksCLIError.invalidProfilesResponse
            }
            try configurationManager.validateDatabricks(profile: profile)
            isConfigured = true
            configuredProfileName = profile.name
            return profileName
        } catch is CancellationError {
            return nil
        } catch DatabricksCLIError.cliNotInstalled {
            isCLIAvailable = false
            updateProfiles([])
            return nil
        } catch {
            if configuredProfileName == attemptedProfileName {
                configuredProfileName = nil
                isConfigured = false
            }
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func installCLIInTerminal() -> DatabricksCLIInstallationResult {
        cliInstaller.installInTerminal()
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

}
