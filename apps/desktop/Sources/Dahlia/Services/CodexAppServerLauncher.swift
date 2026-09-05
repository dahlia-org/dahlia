import DahliaRuntimeSupport
import Foundation

struct BundledCodexAppServerLauncher {
    typealias RuntimeProviderResolver = @Sendable () -> CodexRuntimeProvider

    private let executableLocator: any CodexExecutableLocating
    private let homeLocator: ApplicationSupportCodexHomeLocator
    private let presetSkillInstaller: BundledCodexPresetSkillInstaller
    private let tokenBrokerAuthorization: DahliaTokenBrokerAuthorization
    private let runtimeProviderResolver: RuntimeProviderResolver
    private let arguments: [String]

    init(
        executableLocator: any CodexExecutableLocating = BundleCodexExecutableLocator(),
        homeLocator: ApplicationSupportCodexHomeLocator = ApplicationSupportCodexHomeLocator(),
        presetSkillInstaller: BundledCodexPresetSkillInstaller = BundledCodexPresetSkillInstaller(),
        tokenBrokerAuthorization: DahliaTokenBrokerAuthorization = .shared,
        runtimeProviderResolver: @escaping RuntimeProviderResolver = { CodexRuntimeContextStore.shared.provider },
        arguments: [String] = ["app-server"]
    ) {
        self.executableLocator = executableLocator
        self.homeLocator = homeLocator
        self.presetSkillInstaller = presetSkillInstaller
        self.tokenBrokerAuthorization = tokenBrokerAuthorization
        self.runtimeProviderResolver = runtimeProviderResolver
        self.arguments = arguments
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
        tokenBrokerAuthorization.clear(profile: profile)
        environment["PATH"] = CommandLineToolLocator.searchPath(environment: environment)
        let onLaunch: (@Sendable (pid_t) -> Void)? = if let connectionID = runtimeProvider.accountConnectionID {
            { appServerPID in
                tokenBrokerAuthorization.register(
                    profile: profile,
                    connectionID: connectionID,
                    appServerPID: appServerPID,
                    helperURL: DahliaMCPBundle.expectedExecutableURL()
                )
            }
        } else {
            nil
        }
        return try CodexAppServerProcessTransport(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            currentDirectoryURL: homeURL,
            onLaunch: onLaunch
        )
    }
}
