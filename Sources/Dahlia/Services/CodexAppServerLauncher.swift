import Foundation

protocol CodexAppServerLaunching: Sendable {
    func launch() throws -> any CodexAppServerTransport
}

struct BundledCodexAppServerLauncher: CodexAppServerLaunching {
    private let executableLocator: any CodexExecutableLocating
    private let homeLocator: any CodexHomeLocating
    private let presetSkillInstaller: any CodexPresetSkillInstalling

    init(
        executableLocator: any CodexExecutableLocating = BundleCodexExecutableLocator(),
        homeLocator: any CodexHomeLocating = ApplicationSupportCodexHomeLocator(),
        presetSkillInstaller: any CodexPresetSkillInstalling = BundledCodexPresetSkillInstaller()
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
