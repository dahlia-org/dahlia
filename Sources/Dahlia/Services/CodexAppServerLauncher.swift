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
        let executableURL = try executableLocator.executableURL()
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = homeURL.path
        environment["CODEX_CODE_MODE_HOST_PATH"] = executableURL
            .deletingLastPathComponent()
            .appending(path: "codex-code-mode-host")
            .path
        environment["PATH"] = CommandLineToolLocator.searchPath(environment: environment)
        return try CodexAppServerProcessTransport(
            executableURL: executableURL,
            environment: environment,
            currentDirectoryURL: homeURL
        )
    }
}
