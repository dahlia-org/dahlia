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
        return legacyPath == managedExecutableURL.path
    }

    /// Every Pi process uses the account's managed installation or discovers `pi` on its launch PATH.
    nonisolated static func executableURL(
        defaults: UserDefaults = .standard,
        managedExecutableURL: URL = PiInstaller.executableURL,
        secret: (String) -> String? = { KeychainService.load(key: $0) }
    ) throws -> URL {
        if usesManagedPi(defaults: defaults, managedExecutableURL: managedExecutableURL) {
            guard CommandLineToolLocator.isExecutableFile(atPath: managedExecutableURL.path) else {
                throw PiRuntimeError.piCommandNotFound(managedExecutableURL.path)
            }
            return managedExecutableURL
        }
        let environment = ProcessInfo.processInfo.environment
            .merging(PiLaunchSettings.load(defaults: defaults).commandDiscovery
                .resolvedEnvironment(secret: secret)) { $1 }
        guard let url = CommandLineToolLocator.executableURL(named: "pi", environment: environment) else {
            throw PiRuntimeError.piCommandNotFound(nil)
        }
        return url
    }

    nonisolated static func resourceURL(_ name: String) throws -> URL {
        guard let url = Bundle.appModule.url(forResource: name, withExtension: nil, subdirectory: "PiExtension") else {
            throw PiRuntimeError.helperNotBundled
        }
        return url
    }

    /// Dahlia's bundled skills. Like upstream's `.bundled_manifest`, the Curator never archives or consolidates them.
    nonisolated static let presetSkillNames = ["projects-optimizer", "meeting-reviewer", "workspace-backup", "skill-creator"]

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

/// The app's one account keeps its agent's files in `agent` (`~/.dahlia/agent` in a released build): credentials,
/// `models.json`, and chat sessions. The name names neither Pi nor an account, so another agent could use it.
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

    /// The agent directory of the app's one account. A locator given a folder (tests) keeps it inside that folder.
    var sharedAgentURL: URL {
        guard applicationSupportURL == nil else { return rootURL.appending(path: "agent", directoryHint: .isDirectory) }
        return DahliaApplicationSupport.agentDirectoryURL(profile: DahliaApplicationSupport.profile())
    }

    /// An account's agent directory before the app had one account (`accounts/<local or account id>/pi`).
    func legacyAgentURL(accountKey: String) -> URL {
        accountsURL.appending(path: accountKey, directoryHint: .isDirectory).appending(path: "pi", directoryHint: .isDirectory)
    }

    func agentURL() throws -> URL {
        let url = sharedAgentURL
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
