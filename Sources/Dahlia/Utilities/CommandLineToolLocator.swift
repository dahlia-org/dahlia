import Foundation

enum CommandLineToolLocator {
    private static let supplementalDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
    ]

    static func searchPath(environment: [String: String]) -> String {
        executableDirectories(environment: environment).joined(separator: ":")
    }

    static func executableURL(
        named executableName: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        executableDirectories(environment: environment)
            .lazy
            .map { URL(fileURLWithPath: $0).appending(path: executableName) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func executableDirectories(environment: [String: String]) -> [String] {
        var directories = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        for directory in supplementalDirectories where !directories.contains(directory) {
            directories.append(directory)
        }
        return directories
    }
}
