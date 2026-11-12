import DahliaRuntimeSupport
import Foundation

/// Package declarations and installations belong to the same account directory as Pi's sessions and credentials.
actor PiPackageService {
    static let shared = PiPackageService()
    private var busyAccounts: Set<CodexRuntimeProvider> = []
    private let locator: PiAgentDirectoryLocator

    init(locator: PiAgentDirectoryLocator = .init()) {
        self.locator = locator
    }

    func packages(for account: CodexRuntimeProvider) throws -> [String] {
        try Self.packageSources(in: locator.agentURL(for: account).appending(path: "settings.json"))
    }

    nonisolated static func packageSources(in url: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let settings = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        return Array(Set((settings.objectValue?["packages"]?.arrayValue ?? []).compactMap {
            $0.stringValue ?? $0.objectValue?["source"]?.stringValue
        })).sorted()
    }

    nonisolated static func source(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace || $0.isNewline }),
              ["npm:", "git:", "https://", "http://", "ssh://", "git@"].contains(where: value.hasPrefix)
        else { throw PackageError.invalidSource }
        return value
    }

    func change(_ input: String, installing: Bool, account: CodexRuntimeProvider) async throws {
        let source = try installing ? Self.source(input) : input
        guard !source.isEmpty, !source.hasPrefix("-") else { throw PackageError.invalidSource }
        guard busyAccounts.insert(account).inserted else { throw PackageError.busy }
        defer { busyAccounts.remove(account) }
        let directory = try locator.agentURL(for: account)
        let executable = try PiBundle.executableURL(for: account)
        let environment = try Self.environment(account: account, directory: directory, executable: executable, launch: .load(for: account))
        try await Self.run(
            executable: executable,
            arguments: [installing ? "install" : "remove", source, "--no-approve"],
            environment: environment,
            directory: directory
        )
    }

    nonisolated static func environment(
        account: CodexRuntimeProvider, directory: URL, executable: URL, launch: PiLaunchSettings
    ) throws -> [String: String] {
        var environment = ProcessInfo.processInfo.environment.filter { key, _ in
            !key.hasSuffix("_API_KEY") && !key.hasSuffix("_AUTH_TOKEN") && !key.hasSuffix("_OAUTH_TOKEN") && !key.hasPrefix("PI_")
        }
        environment.merge(launch.environment {
            KeychainService.load(key: PiLaunchSettings.secretKey(for: account, id: $0))
        }) { $1 }
        environment["PATH"] = CommandLineToolLocator.searchPath(for: executable, environment: environment)
        environment["PI_CODING_AGENT_DIR"] = directory.path
        environment["PI_SKIP_VERSION_CHECK"] = "1"
        environment["PI_TELEMETRY"] = "0"
        environment["NO_COLOR"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment.removeValue(forKey: "PI_OFFLINE")
        try PiSandbox.validateSkillsSearchPath(agentURL: directory, searchPath: environment["PATH"] ?? "", cwd: directory)
        return environment
    }

    /// A file drains both outputs without pipe deadlocks; blocking process I/O stays off the cooperative executor.
    nonisolated static func run(executable: URL, arguments: [String], environment: [String: String], directory: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let output = FileManager.default.temporaryDirectory.appending(path: "dahlia-package-\(UUID())")
                    FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
                    defer { try? FileManager.default.removeItem(at: output) }
                    let handle = try FileHandle(forUpdating: output)
                    defer { try? handle.close() }
                    let process = Process()
                    process.executableURL = executable
                    process.arguments = arguments
                    process.environment = environment
                    process.currentDirectoryURL = directory
                    process.standardInput = FileHandle.nullDevice
                    process.standardOutput = handle
                    process.standardError = handle
                    try process.run()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        let length = try handle.seekToEnd()
                        try handle.seek(toOffset: length > 16384 ? length - 16384 : 0)
                        let detail = try String(decoding: handle.readToEnd() ?? Data(), as: UTF8.self)
                        throw PackageError.commandFailed(detail)
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    enum PackageError: LocalizedError {
        case invalidSource
        case busy
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidSource: L10n.agentPackageInvalidSource
            case .busy: L10n.agentPackageBusy
            case let .commandFailed(detail):
                detail.contains("code ENOVERSIONS") ? L10n.agentPackageNoVersions : L10n.agentPackageFailed
            }
        }
    }
}
