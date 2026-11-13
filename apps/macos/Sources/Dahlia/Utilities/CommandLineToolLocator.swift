import Foundation

enum CommandLineToolLocator {
    static let discoveryEnvironmentNames = ["PATH", "NVM_DIR"]

    /// PATH for a child process. The tool's own directory comes first: an npm-installed tool is a
    /// `#!/usr/bin/env node` script whose `node` sits next to it (nvm, fnm, Volta), outside the searched directories.
    static func searchPath(
        for executableURL: URL,
        environment: [String: String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let directory = executableURL.deletingLastPathComponent().path
        return ([directory] + executableDirectories(environment: environment, homeDirectory: homeDirectory)
            .filter { $0 != directory }).joined(separator: ":")
    }

    /// An executable regular file; `FileManager.isExecutableFile` also accepts directories.
    static func isExecutableFile(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    static func executableURL(
        named executableName: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        executableDirectories(environment: environment, homeDirectory: homeDirectory)
            .lazy
            .map { URL(fileURLWithPath: $0).appending(path: executableName) }
            .first { isExecutableFile(atPath: $0.path) }
    }

    /// Finder provides a minimal PATH. Inspect known locations without executing shell startup scripts.
    private static func executableDirectories(environment: [String: String], homeDirectory: URL) -> [String] {
        let supplementalDirectories = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            homeDirectory.appending(path: ".local/bin").path,
            homeDirectory.appending(path: ".bun/bin").path,
            homeDirectory.appending(path: "bin").path,
            homeDirectory.appending(path: "Library/pnpm").path,
            homeDirectory.appending(path: ".volta/bin").path,
            homeDirectory.appending(path: ".npm-global/bin").path,
            "/opt/homebrew/opt/libpq/bin",
        ]
        var seen: Set<String> = []
        let inherited = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        return (inherited + supplementalDirectories + nvmDirectories(environment: environment, homeDirectory: homeDirectory))
            .filter { seen.insert($0).inserted }
    }

    private static func nvmDirectories(environment: [String: String], homeDirectory: URL) -> [String] {
        let path = environment["NVM_DIR"]?.nilIfBlank ?? homeDirectory.appending(path: ".nvm").path
        let root = path == "~" ? homeDirectory : path.hasPrefix("~/")
            ? homeDirectory.appending(path: String(path.dropFirst(2))) : URL(fileURLWithPath: path)
        let versions = (try? FileManager.default.contentsOfDirectory(
            at: root.appending(path: "versions/node"), includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
        )) ?? []
        // Prefer newer versions only as a fallback; an explicit PATH always wins.
        // Keep the configured nvm root even when directory enumeration resolves a symlink.
        return versions.filter {
            $0.lastPathComponent.range(of: #"^v[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil
                && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.sorted {
            $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending
        }.map { root.appending(path: "versions/node/\($0.lastPathComponent)/bin").path }
    }
}
