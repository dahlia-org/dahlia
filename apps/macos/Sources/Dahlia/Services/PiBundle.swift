import DahliaRuntimeSupport
import Foundation

/// The user's installed `pi` command and the Dahlia resources (extension, skills) it runs with.
enum PiBundle {
    nonisolated static func useManagedPiDefaultsKey() -> String {
        "useManagedPi.\(AppAccount.key)"
    }

    /// Preserve accounts that already selected Dahlia's installation; other old paths become PATH discovery.
    nonisolated static func usesManagedPi(
        defaults: UserDefaults = .standard,
        managedExecutableURL: URL = PiInstaller.executableURL
    ) -> Bool {
        let key = useManagedPiDefaultsKey()
        if defaults.object(forKey: key) != nil { return defaults.bool(forKey: key) }
        let legacyPath = defaults.string(forKey: "piExecutablePath.\(AppAccount.key)")?
            .trimmingCharacters(in: .whitespaces)
        return legacyPath == managedExecutableURL.path || legacyPath == PiInstaller.legacyExecutableURL.path
    }

    /// Every Pi process uses the account's managed installation or discovers `pi` on its launch PATH.
    nonisolated static func executableURL(
        defaults: UserDefaults = .standard,
        managedExecutableURL: URL = PiInstaller.executableURL,
        secret: (String) -> String? = { KeychainService.load(key: $0) }
    ) throws -> URL {
        if usesManagedPi(defaults: defaults, managedExecutableURL: managedExecutableURL) {
            if CommandLineToolLocator.isExecutableFile(atPath: managedExecutableURL.path) { return managedExecutableURL }
            // The binary an earlier release installed runs until Settings installs Pi from npm.
            let legacy = PiInstaller.legacyExecutableURL
            guard CommandLineToolLocator.isExecutableFile(atPath: legacy.path) else {
                throw PiRuntimeError.piCommandNotFound(managedExecutableURL.path)
            }
            return legacy
        }
        let environment = ProcessInfo.processInfo.environment
            .merging(PiLaunchSettings.load(defaults: defaults).commandDiscovery
                .resolvedEnvironment(secret: secret)) { $1 }
        guard let url = CommandLineToolLocator.executableURL(named: "pi", environment: environment) else {
            throw PiRuntimeError.piCommandNotFound(nil)
        }
        return url
    }

    /// Dahlia-managed Pi's `bin/pi` links to Pi's `#!/usr/bin/env node` entry point, and macOS has no Node, so its Bun
    /// runs it; `BUN_INSTALL` lets `pi update` find Bun's global folder.
    nonisolated static func processCommand(
        _ executable: URL, _ arguments: [String], environment: [String: String]
    ) -> (executable: URL, arguments: [String], environment: [String: String]) {
        guard executable == PiInstaller.executableURL else { return (executable, arguments, environment) }
        return (PiInstaller.bunURL, [executable.path] + arguments, environment.merging(["BUN_INSTALL": PiInstaller.directoryURL.path]) { $1 })
    }

    nonisolated static func resourceURL(_ name: String) throws -> URL {
        guard let url = Bundle.appModule.url(forResource: name, withExtension: nil, subdirectory: "PiExtension") else {
            throw PiRuntimeError.helperNotBundled
        }
        return url
    }

    /// Dahlia's bundled skills. Like upstream's `.bundled_manifest`, the Curator never archives or consolidates them.
    nonisolated static let presetSkillNames = ["projects-optimizer", "meeting-reviewer", "skill-creator"]

    /// Intake's own procedure. It is not a chat preset: only intake runs load it, and only through `/skill:intake`.
    nonisolated static func intakeSkillURL() -> URL? {
        Bundle.appModule.url(forResource: "intake", withExtension: nil, subdirectory: "AgentSkills")
    }

    nonisolated static func presetSkillURLs() -> [URL] {
        presetSkillNames.compactMap {
            Bundle.appModule.url(forResource: $0, withExtension: nil, subdirectory: "AgentSkills")
        }
    }
}

enum DahliaMCPBundle {
    nonisolated static func expectedExecutableURL(in bundle: Bundle = .main) -> URL {
        bundle.bundleURL.appending(path: "Contents/Helpers/dahlia-mcp")
    }

    nonisolated static func executableURL(in bundle: Bundle = .main) throws -> URL {
        let url = expectedExecutableURL(in: bundle)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw PiRuntimeError.helperNotBundled
        }
        return url
    }
}

/// The app's one account keeps Pi's files in `pi` (`~/.dahlia/pi` in a released build): credentials, `models.json`,
/// chat sessions, and the skills every agent shares, whose path never moves; another runtime would keep its own folder
/// beside it and link to these skills. Each agent's home is in `agents` beside it.
/// `accounts/<account id>/pi` is only read as the migration source and removed with its Dahlia account. Pi never
/// reads `~/.pi`.
struct PiAgentDirectoryLocator: Sendable {
    private let applicationSupportURL: URL?

    init(applicationSupportURL: URL? = nil) {
        self.applicationSupportURL = applicationSupportURL
    }

    private var rootURL: URL {
        applicationSupportURL.map { $0.appending(path: "Dahlia", directoryHint: .isDirectory) }
            ?? DahliaApplicationSupport.currentDirectoryURL
    }

    private var accountsURL: URL { rootURL.appending(path: "accounts", directoryHint: .isDirectory) }

    /// Pi's agent directory for the app's one account. A locator given a folder (tests) keeps it inside that folder.
    var piDirectoryURL: URL {
        guard applicationSupportURL == nil else { return rootURL.appending(path: "pi", directoryHint: .isDirectory) }
        return DahliaApplicationSupport.piDirectoryURL(profile: DahliaApplicationSupport.profile())
    }

    /// An account's agent directory before the app had one account (`accounts/<local or account id>/pi`).
    func legacyAgentURL(accountKey: String) -> URL {
        accountsURL.appending(path: accountKey, directoryHint: .isDirectory).appending(path: "pi", directoryHint: .isDirectory)
    }

    /// Where the agents' homes are (`~/.dahlia/agents` in a released build), beside Pi's directory and apart from its
    /// credentials and settings.
    var agentsURL: URL {
        piDirectoryURL.deletingLastPathComponent().appending(path: "agents", directoryHint: .isDirectory)
    }

    func agentHomeURL(_ directory: String) -> URL {
        agentsURL.appending(path: directory, directoryHint: .isDirectory)
    }

    func agentURL() throws -> URL {
        let url = piDirectoryURL
        try Self.createPrivateDirectory(url)
        try Self.createPrivateDirectory(url.appending(path: "skills", directoryHint: .isDirectory))
        return url
    }

    func sessionsURL() throws -> URL {
        let url = try agentURL().appending(path: "sessions/shared", directoryHint: .isDirectory)
        try Self.createPrivateDirectory(url)
        return url
    }

    /// Chats belong to the account that ran them, like its models; a workspace moved to another account leaves them.
    func sessionsURL(workspaceID: UUID) throws -> URL {
        let url = try agentURL()
            .appending(path: "sessions/\(workspaceID.uuidString.lowercased())", directoryHint: .isDirectory)
        try Self.createPrivateDirectory(url)
        return url
    }

    /// Removes an account's folder and its Codex-era home, which holds the same kind of data.
    func removeAccountDirectory(connectionID: UUID) throws {
        let url = accountsURL.appending(path: connectionID.uuidString.lowercased(), directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let legacyHome = rootURL.appending(path: "CodexAccounts/\(connectionID.uuidString.lowercased())", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: legacyHome.path) {
            try FileManager.default.removeItem(at: legacyHome)
        }
    }

    /// Stable installation ID that Sign in with ChatGPT requires.
    func deviceID() throws -> String {
        let url = try agentURL().appending(path: "dahlia-device-id")
        if let id = try? String(contentsOf: url, encoding: .utf8), UUID(uuidString: id) != nil {
            return id
        }
        let id = UUID().uuidString.lowercased()
        try Data(id.utf8).write(to: url, options: .atomic)
        return id
    }

    static func createPrivateDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            throw PiRuntimeError.launchFailed(error.localizedDescription)
        }
    }
}

/// The app's one account. Its key names the per-account settings and rows that earlier releases kept for each account.
enum AppAccount {
    nonisolated static let key = "local"
}
