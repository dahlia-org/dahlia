import Foundation

enum CommandLineToolLocator {
    /// Apps opened from Finder get launchd's minimal PATH, so the usual install locations are searched too.
    private static let supplementalDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        NSHomeDirectory() + "/.local/bin",
        NSHomeDirectory() + "/bin",
    ]

    /// PATH for a child process. The tool's own directory comes first: an npm-installed tool is a
    /// `#!/usr/bin/env node` script whose `node` sits next to it (nvm, fnm, Volta), outside the searched directories.
    static func searchPath(for executableURL: URL, environment: [String: String]) -> String {
        let directory = executableURL.deletingLastPathComponent().path
        return ([directory] + executableDirectories(environment: environment).filter { $0 != directory }).joined(separator: ":")
    }

    /// An executable regular file; `FileManager.isExecutableFile` also accepts directories.
    static func isExecutableFile(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    static func executableURL(
        named executableName: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        executableDirectories(environment: environment)
            .lazy
            .map { URL(fileURLWithPath: $0).appending(path: executableName) }
            .first { isExecutableFile(atPath: $0.path) }
    }

    private static func executableDirectories(environment: [String: String]) -> [String] {
        var directories = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        for directory in supplementalDirectories where !directories.contains(directory) {
            directories.append(directory)
        }
        return directories
    }
}
