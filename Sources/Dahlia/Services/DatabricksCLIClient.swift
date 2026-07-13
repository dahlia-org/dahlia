import Foundation

/// Databricks CLI の OAuth U2M セッションを利用する薄いラッパー。
struct DatabricksCLIClient {
    struct CommandOutput {
        let standardOutput: Data
        let standardError: Data
        let terminationStatus: Int32
    }

    struct Profile: Decodable, Hashable, Identifiable {
        let name: String
        private let authenticationType: String

        var id: String { name }

        fileprivate var usesOAuthU2M: Bool {
            authenticationType == "databricks-cli"
        }

        private enum CodingKeys: String, CodingKey {
            case name
            case authenticationType = "auth_type"
        }
    }

    typealias CommandRunner = @Sendable ([String]) async throws -> CommandOutput

    private let runCommand: CommandRunner

    init(executableURL: URL? = Self.locateExecutable()) {
        runCommand = { arguments in
            guard let executableURL else {
                throw DatabricksCLIError.cliNotInstalled
            }

            return try await Task.detached(priority: .userInitiated) {
                let process = Process()
                let standardOutput = Pipe()
                let standardError = Pipe()
                process.executableURL = executableURL
                process.arguments = arguments
                process.standardOutput = standardOutput
                process.standardError = standardError

                try process.run()
                let standardOutputTask = Task.detached {
                    standardOutput.fileHandleForReading.readDataToEndOfFile()
                }
                let standardErrorTask = Task.detached {
                    standardError.fileHandleForReading.readDataToEndOfFile()
                }
                process.waitUntilExit()
                let outputData = await standardOutputTask.value
                let errorData = await standardErrorTask.value

                return CommandOutput(
                    standardOutput: outputData,
                    standardError: errorData,
                    terminationStatus: process.terminationStatus
                )
            }.value
        }
    }

    init(runCommand: @escaping CommandRunner) {
        self.runCommand = runCommand
    }

    /// CLI 設定ファイルに登録済みのプロファイルを返す。資格情報の検証やトークン取得は行わない。
    func profiles() async throws -> [Profile] {
        let output = try await runCommand([
            "auth",
            "profiles",
            "--skip-validate",
            "--output",
            "json",
        ])
        try validate(output)

        guard let response = try? JSONDecoder().decode(ProfilesResponse.self, from: output.standardOutput) else {
            throw DatabricksCLIError.invalidProfilesResponse
        }
        return response.profiles
            .filter(\.usesOAuthU2M)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// CLI のキャッシュから短期アクセストークンを取得する。期限切れ時は CLI が自動更新する。
    func accessToken(profile: String) async throws -> String {
        let profile = try normalizedProfile(profile)
        let output = try await runCommand([
            "auth",
            "token",
            "--profile",
            profile,
            "--output",
            "json",
            "--timeout",
            "30s",
        ])
        try validate(output)

        guard let response = try? JSONDecoder().decode(TokenResponse.self, from: output.standardOutput),
              let token = response.accessToken.nilIfBlank
        else {
            throw DatabricksCLIError.invalidTokenResponse
        }
        return token
    }

    static func locateExecutable(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        var candidatePaths = environment["PATH"]?
            .split(separator: ":")
            .map { String($0) + "/databricks" } ?? []
        candidatePaths.append(contentsOf: [
            "/opt/homebrew/bin/databricks",
            "/usr/local/bin/databricks",
        ])

        return candidatePaths.lazy
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func normalizedProfile(_ profile: String) throws -> String {
        guard let profile = profile.nilIfBlank else {
            throw DatabricksCLIError.profileRequired
        }
        return profile
    }

    private func validate(_ output: CommandOutput) throws {
        guard output.terminationStatus == 0 else {
            let detail = String(data: output.standardError, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw DatabricksCLIError.commandFailed(detail: detail?.nilIfBlank)
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
        }
    }

    private struct ProfilesResponse: Decodable {
        let profiles: [Profile]
    }
}

enum DatabricksCLIError: LocalizedError {
    case cliNotInstalled
    case profileRequired
    case commandFailed(detail: String?)
    case invalidProfilesResponse
    case invalidTokenResponse

    var errorDescription: String? {
        switch self {
        case .cliNotInstalled:
            L10n.databricksCLINotInstalled
        case .profileRequired:
            L10n.databricksProfileRequired
        case let .commandFailed(detail):
            if let detail {
                L10n.databricksCLICommandFailed(detail)
            } else {
                L10n.databricksCLICommandFailedWithoutDetail
            }
        case .invalidProfilesResponse:
            L10n.databricksCLIInvalidProfilesResponse
        case .invalidTokenResponse:
            L10n.databricksCLIInvalidTokenResponse
        }
    }
}
