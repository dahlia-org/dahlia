import DahliaRuntimeSupport
import Foundation

/// The folder Dahlia AI's chat works in, set per account under Security. It is writable without additional grants,
/// so it is a folder the user can see rather than one inside Application Support.
struct PiWorkingDirectory: Sendable {
    nonisolated static func defaultsKey(for provider: CodexRuntimeProvider) -> String {
        "piWorkingDirectory.\(provider.accountKey)"
    }

    /// Outside `~/Documents`, which macOS guards with a permission prompt and may sync to iCloud.
    nonisolated static var defaultPath: String {
        DahliaApplicationSupport.profile() == .production ? "~/Dahlia" : "~/Dahlia-Development"
    }

    /// Chat writes this folder freely, so it must hold nothing that runs outside chat's sandbox: not the home folder
    /// itself (shell profiles, tools installed under it, among them Pi) and not the Library folder (app settings).
    nonisolated static func isAllowed(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let folder = URL(fileURLWithPath: path).standardizedFileURL.path
        let library = home + "/Library"
        return path.hasPrefix("/") && !(home + "/").hasPrefix(folder == "/" ? "/" : folder + "/")
            && folder != library && !folder.hasPrefix(library + "/")
    }

    /// Whether the folder is, or contains, a folder on the search path Pi is found and started with. Chat could
    /// replace `pi` there, or put a command in front of the one Pi means to run, and it would run outside the sandbox.
    nonisolated static func holdsCommands(_ folder: URL, searchPath: String, cwd: URL? = nil) -> Bool {
        let folder = PiSandbox.realPath(folder)
        return searchPath.split(separator: ":").contains { entry in
            let entry = PiSandbox.realPath(URL(
                fileURLWithPath: String(entry),
                relativeTo: cwd.map { URL(fileURLWithPath: $0.path, isDirectory: true) }
            ))
            return entry == folder || entry.hasPrefix(folder + "/")
        }
    }

    /// Tests keep chat out of the home folder.
    var override: URL?

    /// The account's folder, created when missing.
    func url(for provider: CodexRuntimeProvider, defaults: UserDefaults = .standard) throws -> URL {
        let configured = (defaults.string(forKey: Self.defaultsKey(for: provider)) ?? "")
            .trimmingCharacters(in: .whitespaces).nilIfBlank ?? Self.defaultPath
        let path = (configured as NSString).expandingTildeInPath
        guard override != nil || Self.isAllowed(path) else {
            throw CodexAppServerError.launchFailed(L10n.agentWorkingDirectoryNotAllowed)
        }
        let url = override ?? URL(fileURLWithPath: path, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw CodexAppServerError.launchFailed(error.localizedDescription)
        }
        // The folder Seatbelt will see: another spelling, letter case, or a link must not reach a refused folder.
        guard override != nil || Self.isAllowed(PiSandbox.realPath(url), home: PiSandbox.realPath(URL(fileURLWithPath: NSHomeDirectory()))) else {
            throw CodexAppServerError.launchFailed(L10n.agentWorkingDirectoryNotAllowed)
        }
        return url
    }
}
