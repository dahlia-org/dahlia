import DahliaRuntimeSupport
import Foundation

struct BundledCodexAppServerLauncher {
    typealias RuntimeProviderResolver = @Sendable () -> CodexRuntimeProvider

    private let executableLocator: any CodexExecutableLocating
    private let homeLocator: ApplicationSupportCodexHomeLocator
    private let presetSkillInstaller: BundledCodexPresetSkillInstaller
    private let tokenBrokerAuthorization: DahliaTokenBrokerAuthorization
    private let runtimeProviderResolver: RuntimeProviderResolver

    init(
        executableLocator: any CodexExecutableLocating = BundleCodexExecutableLocator(),
        homeLocator: ApplicationSupportCodexHomeLocator = ApplicationSupportCodexHomeLocator(),
        presetSkillInstaller: BundledCodexPresetSkillInstaller = BundledCodexPresetSkillInstaller(),
        tokenBrokerAuthorization: DahliaTokenBrokerAuthorization = .shared,
        runtimeProviderResolver: @escaping RuntimeProviderResolver = { CodexRuntimeContextStore.shared.provider }
    ) {
        self.executableLocator = executableLocator
        self.homeLocator = homeLocator
        self.presetSkillInstaller = presetSkillInstaller
        self.tokenBrokerAuthorization = tokenBrokerAuthorization
        self.runtimeProviderResolver = runtimeProviderResolver
    }

    func launch() throws -> any CodexAppServerTransport {
        let runtimeProvider = runtimeProviderResolver()
        let homeURL = try homeLocator.homeURL(connectionID: runtimeProvider.accountConnectionID)
        try presetSkillInstaller.install(into: homeURL)
        let executableURL = try executableLocator.executableURL()
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = homeURL.path
        environment["CODEX_CODE_MODE_HOST_PATH"] = executableURL
            .deletingLastPathComponent()
            .appending(path: "codex-code-mode-host")
            .path
        let profile = DahliaApplicationSupport.profile()
        if let connectionID = runtimeProvider.accountConnectionID {
            environment[DahliaTokenBrokerProtocol.capabilityEnvironmentKey] = try tokenBrokerAuthorization.rotate(
                profile: profile,
                connectionID: connectionID
            )
        } else {
            tokenBrokerAuthorization.clear(profile: profile)
            environment.removeValue(forKey: DahliaTokenBrokerProtocol.capabilityEnvironmentKey)
        }
        environment["PATH"] = CommandLineToolLocator.searchPath(environment: environment)
        return try CodexAppServerProcessTransport(
            executableURL: executableURL,
            environment: environment,
            currentDirectoryURL: homeURL
        )
    }
}
