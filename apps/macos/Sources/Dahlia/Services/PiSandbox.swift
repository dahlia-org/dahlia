import DahliaMeetingAccess
import DahliaRuntimeSupport
import Foundation

/// Runs what chat does on this Mac's disk (bash commands and the file tools' reads and writes) under Apple Seatbelt
/// (`PiExtension/pi.sb`): it writes only the working folder, reads the system but nothing else of the user's except
/// Dahlia's skills, screenshots, and database, and uses the network freely.
enum PiSandbox {
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
        applicationSupportURL: URL = DahliaApplicationSupport.currentDirectoryURL
    ) throws -> [String] {
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
        return try ["/usr/bin/sandbox-exec", "-f", PiBundle.resourceURL("pi.sb").path] + parameters.flatMap { ["-D", "\($0)=\($1)"] }
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

    /// Seatbelt matches resolved paths, and Foundation's resolution drops `/private`. A missing path stays as written.
    nonisolated static func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
