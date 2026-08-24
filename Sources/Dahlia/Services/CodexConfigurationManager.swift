import Foundation

actor CodexConfigurationManager {
    private let homeLocator: ApplicationSupportCodexHomeLocator

    init(homeLocator: ApplicationSupportCodexHomeLocator = ApplicationSupportCodexHomeLocator()) {
        self.homeLocator = homeLocator
    }

    @discardableResult
    func configureChatGPTSubscription() throws -> Bool {
        let configURL = try configURL()
        guard FileManager.default.fileExists(atPath: configURL.path) else { return false }

        do {
            try FileManager.default.removeItem(at: configURL)
            return true
        } catch {
            throw CodexConfigurationError.updateFailed(error.localizedDescription)
        }
    }

    @discardableResult
    func configureDatabricks(profile: DatabricksCLIClient.Profile) throws -> Bool {
        let (profileName, workspaceURL) = try validatedDatabricksValues(profile: profile)
        let baseURL = workspaceURL.appending(path: "ai-gateway/codex/v1").absoluteString
        let tokenCommand = "databricks auth token --profile \(shellQuote(profileName)) --output json "
            + "| /usr/bin/plutil -extract access_token raw -o - -"
        let configuration = """
        model_provider = "Databricks"

        [model_providers.Databricks]
        name = "Databricks AI Gateway"
        base_url = "\(tomlEscape(baseURL))"
        wire_api = "responses"

        [model_providers.Databricks.auth]
        command = "sh"
        args = ["-c", "\(tomlEscape(tokenCommand))"]
        timeout_ms = 5000
        refresh_interval_ms = 1800000
        """ + "\n"

        return try writeIfChanged(Data(configuration.utf8))
    }

    nonisolated func validateDatabricks(profile: DatabricksCLIClient.Profile) throws {
        _ = try validatedDatabricksValues(profile: profile)
    }

    func configurationData() throws -> Data? {
        let configURL = try configURL()
        guard FileManager.default.fileExists(atPath: configURL.path) else { return nil }
        do {
            return try Data(contentsOf: configURL)
        } catch {
            throw CodexConfigurationError.updateFailed(error.localizedDescription)
        }
    }

    func restoreConfiguration(_ data: Data?) throws {
        let configURL = try configURL()
        if let data {
            _ = try writeIfChanged(data)
        } else if FileManager.default.fileExists(atPath: configURL.path) {
            try FileManager.default.removeItem(at: configURL)
        }
    }

    private nonisolated func validatedDatabricksValues(
        profile: DatabricksCLIClient.Profile
    ) throws -> (profileName: String, workspaceURL: URL) {
        guard let profileName = profile.name.nilIfBlank else {
            throw CodexConfigurationError.databricksProfileRequired
        }
        return try (profileName, normalizedDatabricksWorkspaceURL(profile.host))
    }

    nonisolated func normalizedDatabricksWorkspaceURL(_ value: String?) throws -> URL {
        guard let value = value?.nilIfBlank,
              var components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else {
            throw CodexConfigurationError.invalidDatabricksWorkspaceURL
        }
        components.scheme = "https"
        components.host = components.host?.lowercased()
        if components.port == 443 {
            components.port = nil
        }
        components.path = ""
        guard let url = components.url else {
            throw CodexConfigurationError.invalidDatabricksWorkspaceURL
        }
        return url
    }

    private func configURL() throws -> URL {
        try homeLocator.homeURL().appending(path: "config.toml")
    }

    private func writeIfChanged(_ data: Data) throws -> Bool {
        let configURL = try configURL()
        if FileManager.default.contents(atPath: configURL.path) == data { return false }

        do {
            try data.write(to: configURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: configURL.path
            )
            return true
        } catch {
            throw CodexConfigurationError.updateFailed(error.localizedDescription)
        }
    }

    private nonisolated func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private nonisolated func tomlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}
