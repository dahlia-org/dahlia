import DahliaRuntimeSupport
import Foundation

/// The user's installed `pi` command and the Dahlia resources (extension, skills) it runs with.
enum PiBundle {
    /// Absolute path of the `pi` command set in Agents settings; empty searches for one.
    nonisolated static let executablePathDefaultsKey = "piExecutablePath"

    /// The command Dahlia runs: the path set in Settings, else `pi` on the search path.
    nonisolated static func executableURL(defaults: UserDefaults = .standard) throws -> URL {
        let configured = (defaults.string(forKey: executablePathDefaultsKey) ?? "").trimmingCharacters(in: .whitespaces)
        guard configured.isEmpty else {
            let path = (configured as NSString).expandingTildeInPath
            guard CommandLineToolLocator.isExecutableFile(atPath: path) else {
                throw CodexAppServerError.piCommandNotFound(path)
            }
            return URL(fileURLWithPath: path)
        }
        guard let url = CommandLineToolLocator.executableURL(named: "pi") else {
            throw CodexAppServerError.piCommandNotFound(nil)
        }
        return url
    }

    nonisolated static func resourceURL(_ name: String) throws -> URL {
        guard let url = Bundle.appModule.url(forResource: name, withExtension: nil, subdirectory: "PiExtension") else {
            throw CodexAppServerError.helperNotBundled
        }
        return url
    }

    nonisolated static func presetSkillURLs() -> [URL] {
        ["projects-optimizer", "meeting-reviewer"].compactMap {
            Bundle.appModule.url(forResource: $0, withExtension: nil, subdirectory: "CodexSkills")
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
            throw CodexAppServerError.helperNotBundled
        }
        return url
    }
}

/// Each account's folder is `accounts/<account id>` (`accounts/local` for the Local Account); Pi's agent directory is
/// its `pi` folder, holding that account's credentials, `models.json`, and chat sessions. Pi never reads `~/.pi`.
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

    func accountURL(for provider: CodexRuntimeProvider) -> URL {
        let name = switch provider {
        case .local: "local"
        case let .databricks(connectionID), let .dahlia(connectionID): connectionID.uuidString.lowercased()
        }
        return accountsURL.appending(path: name, directoryHint: .isDirectory)
    }

    func agentURL(for provider: CodexRuntimeProvider) throws -> URL {
        let url = accountURL(for: provider).appending(path: "pi", directoryHint: .isDirectory)
        try Self.createPrivateDirectory(url)
        return url
    }

    /// Chats belong to the account that ran them, like its models; a workspace moved to another account leaves them.
    func sessionsURL(for provider: CodexRuntimeProvider, workspaceID: UUID) throws -> URL {
        let url = try agentURL(for: provider)
            .appending(path: "sessions/\(workspaceID.uuidString.lowercased())", directoryHint: .isDirectory)
        try Self.createPrivateDirectory(url)
        return url
    }

    /// Removes an account's folder and its Codex-era home, which holds the same kind of data.
    func removeAccountDirectory(connectionID: UUID) throws {
        let url = accountURL(for: .dahlia(connectionID: connectionID))
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let legacyHome = rootURL.appending(path: "CodexAccounts/\(connectionID.uuidString.lowercased())", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: legacyHome.path) {
            try FileManager.default.removeItem(at: legacyHome)
        }
    }

    /// Stable installation ID that Sign in with ChatGPT requires.
    func deviceID() throws -> String {
        let url = try agentURL(for: .local).appending(path: "dahlia-device-id")
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
            throw CodexAppServerError.launchFailed(error.localizedDescription)
        }
    }
}
