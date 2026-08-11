import Foundation

struct BundledCodexAppServerLauncher {
    private let executableLocator: any CodexExecutableLocating
    private let homeLocator: ApplicationSupportCodexHomeLocator
    private let presetSkillInstaller: BundledCodexPresetSkillInstaller

    init(
        executableLocator: any CodexExecutableLocating = BundleCodexExecutableLocator(),
        homeLocator: ApplicationSupportCodexHomeLocator = ApplicationSupportCodexHomeLocator(),
        presetSkillInstaller: BundledCodexPresetSkillInstaller = BundledCodexPresetSkillInstaller()
    ) {
        self.executableLocator = executableLocator
        self.homeLocator = homeLocator
        self.presetSkillInstaller = presetSkillInstaller
    }

    func launch() throws -> any CodexAppServerTransport {
        let homeURL = try homeLocator.homeURL()
        try presetSkillInstaller.install(into: homeURL)
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = homeURL.path
        environment["PATH"] = CommandLineToolLocator.searchPath(environment: environment)
        return try CodexAppServerProcessTransport(
            executableURL: executableLocator.executableURL(),
            environment: environment,
            currentDirectoryURL: homeURL
        )
    }
}
