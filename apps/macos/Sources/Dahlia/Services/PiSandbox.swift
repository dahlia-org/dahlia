import DahliaMeetingAccess
import DahliaRuntimeSupport
import Foundation

/// Runs what chat does on this Mac's disk (bash commands and the file tools' reads and writes) under Apple Seatbelt
/// (`PiExtension/pi.sb`): the working folder and explicit per-account grants are accessible, while runtime code
/// and account data remain protected. Network access is allowed.
enum PiSandbox {
    struct DefaultFileAccess: Sendable {
        var resources: [PiFileAccessSettings.Grant] = []
        var data: [PiFileAccessSettings.Grant] = []
        var system: [PiFileAccessSettings.Grant] = []
    }

    /// Skills stay writable across chat processes, so no Pi launch may search them for executable commands.
    nonisolated static func validateSkillsSearchPath(agentURL: URL, searchPath: String, cwd: URL) throws {
        guard !PiWorkingDirectory.holdsCommands(agentURL.appending(path: "skills"), searchPath: searchPath, cwd: cwd) else {
            throw PiRuntimeError.launchFailed(L10n.agentSkillsPathConflict)
        }
    }

    /// User-visible defaults. System exceptions and protected runtime/data rules still take precedence.
    nonisolated static func defaultFileAccess(cwd: URL, agentURL: URL) -> DefaultFileAccess {
        let writable = [cwd, temporaryDirectory, agentURL.appending(path: "skills")]
        let readOnly = [piTemporaryDirectory, agentURL.appending(path: "npm"), agentURL.appending(path: "git")]
            + PiBundle.presetSkillURLs()
        let database = MeetingAccessStore.defaultDatabaseURL.path
        let files = [database, database + "-wal", database + "-shm"]
        // Keep the displayed system directories aligned with pi.sb; individual device files are omitted.
        let system = [
            "/System",
            "/usr",
            "/bin",
            "/sbin",
            "/Library/Developer",
            "/Library/Apple",
            "/Library/Frameworks",
            "/Applications",
            "/opt",
            "/private/etc",
            "/private/var/db/timezone",
            "/private/var/select",
        ]
        return DefaultFileAccess(
            resources: writable.map { .init(path: realPath($0), isDirectory: true, access: .readWrite) }
                + readOnly.map { .init(path: realPath($0), isDirectory: true) },
            data: [.init(path: realPath(ScreenshotFileStore.defaultDirectory), isDirectory: true)]
                + files.map { .init(path: $0, isDirectory: false) },
            system: system.map { .init(path: $0, isDirectory: true) }
        )
    }

    /// The sandbox's temporary and home folder; the user's own are out of reach there.
    nonisolated static let temporaryDirectory = FileManager.default.temporaryDirectory
        .appending(path: "dahlia-chat", directoryHint: .isDirectory)
    /// Pi's own temporary folder for chat. The sandbox reads it (Pi saves a command's full output there) but never
    /// writes it, because Pi loads its transpiled extensions from it.
    nonisolated static let piTemporaryDirectory = FileManager.default.temporaryDirectory
        .appending(path: "dahlia-pi", directoryHint: .isDirectory)

    /// The command prefix that runs a command under the profile.
    nonisolated static func command(
        cwd: URL,
        agentURL: URL,
        piExecutableURL: URL,
        applicationSupportURL: URL = DahliaApplicationSupport.currentDirectoryURL,
        fileAccess: PiFileAccessSettings = .init(),
        searchPath: String = "",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) throws -> [String] {
        try validateSkillsSearchPath(agentURL: agentURL, searchPath: searchPath, cwd: cwd)
        try PiAgentDirectoryLocator.createPrivateDirectory(temporaryDirectory)
        try PiAgentDirectoryLocator.createPrivateDirectory(piTemporaryDirectory)
        let skills = PiBundle.presetSkillURLs().first?.deletingLastPathComponent()
        let parameters: KeyValuePairs = try [
            "WORK": realPath(cwd),
            "TMP": realPath(temporaryDirectory),
            "PI_TMP": realPath(piTemporaryDirectory),
            "PI": installRoot(of: piExecutableURL),
            "RESOURCES": realPath(PiBundle.resourceURL("dahlia.ts").deletingLastPathComponent().deletingLastPathComponent()),
            "AGENT": realPath(agentURL),
            "SKILLS": skills.map(realPath) ?? "/var/empty/no-skills",
            "FILE_STORE": realPath(ScreenshotFileStore.defaultDirectory),
            "DATABASE": realPath(MeetingAccessStore.defaultDatabaseURL),
            "APP_SUPPORT": realPath(applicationSupportURL),
            // A development build must not reach a released user's data either.
            "RELEASED_APP_SUPPORT": realPath(DahliaApplicationSupport.directoryURL(profile: .production)),
        ]
        var arguments = parameters.flatMap { ["-D", "\($0)=\($1)"] }
        var rules: [String] = []
        for (index, grant) in fileAccess.grants.enumerated() {
            let grant = try PiFileAccessSettings.resolved(grant, searchPath: searchPath, home: home, cwd: cwd, environment: environment)
            let parameter = "EXTRA_\(index)"
            arguments += ["-D", "\(parameter)=\(grant.path)"]
            let operations = grant.access == .readWrite ? "file-read* file-write*" : "file-read*"
            let filter = grant.isDirectory ? "subpath" : "literal"
            rules.append("(allow \(operations) (\(filter) (param \"\(parameter)\")))")
        }
        // WORK/TMP and additional grants must not make shell startup code writable.
        var shellRules: [String] = []
        for (index, path) in try shellStartupPaths(home: home, environment: environment, cwd: cwd).enumerated() {
            let parameter = "SHELL_STARTUP_\(index)"
            arguments += ["-D", "\(parameter)=\(path)"]
            shellRules.append("(deny file-write* (subpath (param \"\(parameter)\")))")
        }
        let profile = try String(contentsOf: PiBundle.resourceURL("pi.sb"), encoding: .utf8)
            .replacingOccurrences(of: "; ADDITIONAL_FILE_ACCESS", with: rules.joined(separator: "\n"))
            .replacingOccurrences(of: "; SHELL_STARTUP_PROTECTION", with: shellRules.joined(separator: "\n"))
        return ["/usr/bin/sandbox-exec", "-p", profile] + arguments
    }

    /// Standard startup inputs plus explicit startup locations from the actual launch environment.
    /// Keep both spellings so a symlink's target and replacement of the link itself stay protected.
    nonisolated static func shellStartupPaths(
        home: String = NSHomeDirectory(), environment: [String: String], cwd: URL? = nil
    ) throws -> [String] {
        let base = cwd.map { URL(fileURLWithPath: $0.path, isDirectory: true) }
        func url(_ value: String) -> URL {
            let path = value == "~" ? home : value.hasPrefix("~/") ? home + value.dropFirst() : value
            return URL(fileURLWithPath: path, relativeTo: base)
        }
        let zsh = [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".zlogout"]
        let names = zsh + [".bashrc", ".bash_profile", ".bash_login", ".bash_logout", ".profile", ".cshrc", ".tcshrc", ".login", ".logout"]
        var paths: [URL] = []
        let homes = [url(home)] + (environment["HOME"].flatMap(\.nilIfBlank).map { [url($0)] } ?? [])
        for folder in homes {
            paths += names.map { folder.appending(path: $0) }
            paths.append(folder.appending(path: ".config/fish"))
        }
        if let folder = environment["ZDOTDIR"]?.nilIfBlank { paths += zsh.map { url(folder).appending(path: $0) } }
        if let folder = environment["XDG_CONFIG_HOME"]?.nilIfBlank { paths.append(url(folder).appending(path: "fish")) }
        for name in ["BASH_ENV", "ENV"] {
            if let file = environment[name]?.nilIfBlank {
                // Bourne shells expand these values. Accept paths, never evaluate shell expressions outside Seatbelt.
                guard !file.contains("$"), !file.contains("`"), !file.hasPrefix("~") || file == "~" || file.hasPrefix("~/") else {
                    throw PiRuntimeError.launchFailed(L10n.agentShellStartupPathRequired)
                }
                paths.append(url(file))
            }
        }
        return Set(paths.flatMap { [$0.path, realPath($0)] }).sorted()
    }

    nonisolated static func overlapsShellStartupFiles(
        _ path: String,
        isDirectory: Bool,
        home: String = NSHomeDirectory(),
        environment: [String: String],
        cwd: URL? = nil
    ) throws -> Bool {
        try shellStartupPaths(home: home, environment: environment, cwd: cwd).contains {
            path == $0 || path.hasPrefix($0 + "/") || (isDirectory && $0.hasPrefix(path + "/"))
        }
    }

    /// What an installed Pi runs from: its folder, or for an npm package the prefix that holds it, its dependencies,
    /// and its `node`.
    nonisolated static func installRoot(of executableURL: URL, home: String = NSHomeDirectory()) -> String {
        let path = realPath(executableURL)
        let folder = (path as NSString).deletingLastPathComponent
        guard let modules = path.range(of: "/node_modules/") else { return folder }
        let prefix = String(path[..<modules.lowerBound])
        let root = prefix.hasSuffix("/lib") ? String(prefix.dropLast(4)) : prefix
        // A package installed in the home folder itself must not close the whole home, working folder included;
        // its `node_modules` still holds everything Pi loads, hoisted dependencies too.
        return (home + "/").hasPrefix(root + "/") ? prefix + "/node_modules" : root
    }

    /// Seatbelt matches resolved paths. Resolve existing ancestors and dangling links too, so future files are protected.
    nonisolated static func realPath(_ url: URL) -> String {
        var visited: Set<String> = []
        func resolve(_ url: URL) -> String {
            if let resolved = realpath(url.path, nil) {
                defer { free(resolved) }
                return String(cString: resolved)
            }
            guard visited.insert(url.path).inserted else { return url.path }
            let parent = url.deletingLastPathComponent()
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
                return resolve(URL(fileURLWithPath: target, relativeTo: URL(fileURLWithPath: parent.path, isDirectory: true)))
            }
            guard parent.path != url.path else { return url.path }
            return URL(fileURLWithPath: resolve(parent), isDirectory: true).appending(path: url.lastPathComponent).path
        }
        return resolve(url)
    }
}
