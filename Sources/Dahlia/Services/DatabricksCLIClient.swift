import Foundation

struct DatabricksCLIClient {
    struct CommandOutput {
        let standardOutput: Data
        let standardError: Data
        let terminationStatus: Int32
    }

    struct Profile: Decodable, Hashable, Identifiable {
        let name: String
        let host: String?
        let workspaceID: String?
        private let authenticationType: String

        var id: String { name }

        fileprivate var usesOAuthU2M: Bool {
            authenticationType == "databricks-cli"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            host = try container.decodeIfPresent(String.self, forKey: .host)
            authenticationType = try container.decode(String.self, forKey: .authenticationType)
            if let stringValue = try? container.decode(String.self, forKey: .workspaceID) {
                workspaceID = stringValue
            } else if let integerValue = try? container.decode(Int64.self, forKey: .workspaceID) {
                workspaceID = String(integerValue)
            } else {
                workspaceID = nil
            }
        }

        private enum CodingKeys: String, CodingKey {
            case name
            case host
            case authenticationType = "auth_type"
            case workspaceID = "workspace_id"
        }
    }

    typealias CommandRunner = @Sendable ([String]) async throws -> CommandOutput

    private let runCommand: CommandRunner

    init(executableURL: URL? = Self.locateExecutable()) {
        runCommand = { arguments in
            guard let executableURL else {
                throw DatabricksCLIError.cliNotInstalled
            }
            return try await Self.execute(executableURL: executableURL, arguments: arguments)
        }
    }

    init(runCommand: @escaping CommandRunner) {
        self.runCommand = runCommand
    }

    func profiles() async throws -> [Profile] {
        let output = try await runCommand([
            "auth",
            "profiles",
            "--skip-validate",
            "--output",
            "json",
        ])
        try Task.checkCancellation()
        try validate(output)

        guard let response = try? JSONDecoder().decode(ProfilesResponse.self, from: output.standardOutput) else {
            throw DatabricksCLIError.invalidProfilesResponse
        }
        return response.profiles
            .filter(\.usesOAuthU2M)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func locateExecutable(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        CommandLineToolLocator.executableURL(named: "databricks", environment: environment)
    }

    private static func execute(executableURL: URL, arguments: [String]) async throws -> CommandOutput {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError

        let standardOutputTask = Task { try await readToEnd(standardOutput.fileHandleForReading) }
        let standardErrorTask = Task { try await readToEnd(standardError.fileHandleForReading) }
        defer {
            standardOutputTask.cancel()
            standardErrorTask.cancel()
        }

        try Task.checkCancellation()
        let terminationStatus = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in
                    continuation.resume(returning: process.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
        try Task.checkCancellation()

        let outputData = try await standardOutputTask.value
        let errorData = try await standardErrorTask.value
        return CommandOutput(
            standardOutput: outputData,
            standardError: errorData,
            terminationStatus: terminationStatus
        )
    }

    private static func readToEnd(_ handle: FileHandle) async throws -> Data {
        var data = Data()
        for try await byte in handle.bytes {
            data.append(byte)
        }
        return data
    }

    private func validate(_ output: CommandOutput) throws {
        guard output.terminationStatus == 0 else {
            let detail = String(data: output.standardError, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw DatabricksCLIError.commandFailed(detail: detail?.nilIfBlank)
        }
    }

    private struct ProfilesResponse: Decodable {
        let profiles: [Profile]
    }
}
