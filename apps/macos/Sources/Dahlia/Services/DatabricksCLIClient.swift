import Foundation
import os

struct DatabricksCLIClient {
    enum AuthenticationResult: Equatable, Sendable {
        case alreadyAuthenticated
        case browserLoginCompleted
    }

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
            return try await Self.execute(
                executableURL: executableURL,
                arguments: arguments,
                capturesStandardOutput: arguments.prefix(2) != ["auth", "token"]
            )
        }
    }

    init(runCommand: @escaping CommandRunner) {
        self.runCommand = runCommand
    }

    func profiles() async throws -> [Profile] {
        let output = try await runValidatedCommand([
            "auth",
            "profiles",
            "--skip-validate",
            "--output",
            "json",
        ])

        guard let response = try? JSONDecoder().decode(ProfilesResponse.self, from: output.standardOutput) else {
            throw DatabricksCLIError.invalidProfilesResponse
        }
        return response.profiles
            .filter(\.usesOAuthU2M)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func ensureAuthenticated(
        profileName: String,
        onBrowserLoginRequired: @Sendable () async -> Void = {}
    ) async throws -> AuthenticationResult {
        let tokenArguments = [
            "auth",
            "token",
            "--profile",
            profileName,
            "--output",
            "json",
        ]
        let tokenOutput = try await runCommand(tokenArguments)
        try Task.checkCancellation()
        guard tokenOutput.terminationStatus != 0 else { return .alreadyAuthenticated }
        guard requiresBrowserLogin(tokenOutput) else {
            try validate(tokenOutput)
            return .alreadyAuthenticated
        }

        await onBrowserLoginRequired()
        try Task.checkCancellation()
        _ = try await runValidatedCommand([
            "auth",
            "login",
            "--profile",
            profileName,
        ])
        _ = try await runValidatedCommand(tokenArguments)
        return .browserLoginCompleted
    }

    static func locateExecutable(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        CommandLineToolLocator.executableURL(named: "databricks", environment: environment)
    }

    private static func execute(
        executableURL: URL,
        arguments: [String],
        capturesStandardOutput: Bool
    ) async throws -> CommandOutput {
        let process = Process()
        let launchState = OSAllocatedUnfairLock(initialState: false)
        let standardOutput = capturesStandardOutput ? Pipe() : nil
        let standardError = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = standardOutput ?? FileHandle.nullDevice
        process.standardError = standardError

        let standardOutputTask = standardOutput.map { pipe in
            Task { try await readToEnd(pipe.fileHandleForReading) }
        }
        let standardErrorTask = Task { try await readToEnd(standardError.fileHandleForReading) }
        defer {
            standardOutputTask?.cancel()
            standardErrorTask.cancel()
        }

        try Task.checkCancellation()
        let terminationStatus = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Process duplicates these descriptors during launch. Closing the parent's
                // write ends when this setup completes lets the async readers receive EOF.
                defer {
                    closeParentWriteHandles(
                        standardOutput: standardOutput,
                        standardError: standardError
                    )
                }
                process.terminationHandler = { process in
                    continuation.resume(returning: process.terminationStatus)
                }
                do {
                    let didLaunch = try launchState.withLock { isCancelled in
                        guard !isCancelled else { return false }
                        try process.run()
                        return true
                    }
                    if !didLaunch {
                        process.terminationHandler = nil
                        continuation.resume(throwing: CancellationError())
                    }
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            launchState.withLock { isCancelled in
                isCancelled = true
                if process.isRunning {
                    process.terminate()
                }
            }
        }
        try Task.checkCancellation()

        let outputData = try await standardOutputTask?.value ?? Data()
        let errorData = try await standardErrorTask.value
        return CommandOutput(
            standardOutput: outputData,
            standardError: errorData,
            terminationStatus: terminationStatus
        )
    }

    private static func closeParentWriteHandles(
        standardOutput: Pipe?,
        standardError: Pipe
    ) {
        try? standardOutput?.fileHandleForWriting.close()
        try? standardError.fileHandleForWriting.close()
    }

    private static func readToEnd(_ handle: FileHandle) async throws -> Data {
        let chunks = AsyncThrowingStream<Data, any Error> { continuation in
            handle.readabilityHandler = { readableHandle in
                do {
                    guard let chunk = try readableHandle.read(upToCount: 64 * 1024), !chunk.isEmpty else {
                        readableHandle.readabilityHandler = nil
                        continuation.finish()
                        return
                    }
                    continuation.yield(chunk)
                } catch {
                    readableHandle.readabilityHandler = nil
                    continuation.finish(throwing: error)
                }
            }
        }
        defer {
            handle.readabilityHandler = nil
            try? handle.close()
        }

        var data = Data()
        for try await chunk in chunks {
            data.append(chunk)
        }
        return data
    }

    private func runValidatedCommand(_ arguments: [String]) async throws -> CommandOutput {
        let output = try await runCommand(arguments)
        try Task.checkCancellation()
        try validate(output)
        return output
    }

    private func validate(_ output: CommandOutput) throws {
        guard output.terminationStatus == 0 else {
            let detail = String(data: output.standardError, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw DatabricksCLIError.commandFailed(detail: detail?.nilIfBlank)
        }
    }

    private func requiresBrowserLogin(_ output: CommandOutput) -> Bool {
        guard let detail = String(data: output.standardError, encoding: .utf8)?.lowercased() else {
            return false
        }
        // These are Databricks CLI's explicit diagnostics for a missing cached login
        // or an invalid refresh token. Other failures need their original error.
        return detail.contains("refresh token is invalid")
            || detail.contains("databricks oauth is not configured for this host")
    }

    private struct ProfilesResponse: Decodable {
        let profiles: [Profile]
    }
}
