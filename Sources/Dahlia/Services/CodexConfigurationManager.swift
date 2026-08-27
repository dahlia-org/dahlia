import Foundation

actor CodexConfigurationManager {
    private enum TOMLStringContext {
        case basic
        case literal
        case multilineBasic
        case multilineLiteral
    }

    private let homeLocator: ApplicationSupportCodexHomeLocator

    init(homeLocator: ApplicationSupportCodexHomeLocator = ApplicationSupportCodexHomeLocator()) {
        self.homeLocator = homeLocator
    }

    @discardableResult
    func configureChatGPTSubscription() throws -> Bool {
        let configuration: String
        if let data = try configurationData() {
            guard let decodedConfiguration = String(data: data, encoding: .utf8) else {
                throw CodexConfigurationError.updateFailed(CocoaError(.fileReadInapplicableStringEncoding).localizedDescription)
            }
            configuration = decodedConfiguration
        } else {
            configuration = ""
        }
        let firstTableStart = rootConfigurationEnd(in: configuration)
        let rootConfiguration = String(configuration[..<firstTableStart])
        let modelProviderPattern =
            #"(?m)(^[\t ]*(?:model_provider|"model_provider"|'model_provider')[\t ]*=[\t ]*)(?:"[^"\r\n]*"|'[^'\r\n]*')"#
        let openAIModelProvider = #"model_provider = "openai""#
        let updatedConfiguration = if rootConfiguration.range(of: modelProviderPattern, options: .regularExpression) != nil {
            rootConfiguration.replacingOccurrences(
                of: modelProviderPattern,
                with: #"$1"openai""#,
                options: .regularExpression
            ) + String(configuration[firstTableStart...])
        } else {
            openAIModelProvider + "\n\n" + configuration
        }
        return try writeIfChanged(Data(updatedConfiguration.utf8))
    }

    private nonisolated func rootConfigurationEnd(in configuration: String) -> String.Index {
        var lineStart = configuration.startIndex
        var stringContext: TOMLStringContext?
        while lineStart < configuration.endIndex {
            let lineRange = configuration.lineRange(for: lineStart ..< lineStart)
            let line = configuration[lineRange]
            if stringContext == nil,
               line.drop(while: { $0 == " " || $0 == "\t" }).first == "[" {
                return lineStart
            }
            updateTOMLStringContext(in: line, context: &stringContext)
            lineStart = lineRange.upperBound
        }
        return configuration.endIndex
    }

    private nonisolated func updateTOMLStringContext(
        in line: Substring,
        context: inout TOMLStringContext?
    ) {
        var index = line.startIndex
        while index < line.endIndex {
            let remainder = line[index...]
            switch context {
            case nil:
                if remainder.first == "#" { return }
                if remainder.hasPrefix("\"\"\"") {
                    context = .multilineBasic
                    index = line.index(index, offsetBy: 3)
                } else if remainder.hasPrefix("'''") {
                    context = .multilineLiteral
                    index = line.index(index, offsetBy: 3)
                } else if remainder.first == "\"" {
                    context = .basic
                    index = line.index(after: index)
                } else if remainder.first == "'" {
                    context = .literal
                    index = line.index(after: index)
                } else {
                    index = line.index(after: index)
                }
            case .basic:
                if remainder.first == "\\" {
                    index = line.index(after: index)
                    if index < line.endIndex { index = line.index(after: index) }
                } else if remainder.first == "\"" {
                    context = nil
                    index = line.index(after: index)
                } else {
                    index = line.index(after: index)
                }
            case .literal:
                if remainder.first == "'" { context = nil }
                index = line.index(after: index)
            case .multilineBasic:
                if remainder.first == "\\" {
                    index = line.index(after: index)
                    if index < line.endIndex { index = line.index(after: index) }
                } else if remainder.hasPrefix("\"\"\"") {
                    context = nil
                    index = line.index(index, offsetBy: 3)
                } else {
                    index = line.index(after: index)
                }
            case .multilineLiteral:
                if remainder.hasPrefix("'''") {
                    context = nil
                    index = line.index(index, offsetBy: 3)
                } else {
                    index = line.index(after: index)
                }
            }
        }
        if context == .basic || context == .literal { context = nil }
    }

    @discardableResult
    func configureDatabricks(profile: DatabricksCLIClient.Profile) throws -> Bool {
        let (profileName, workspaceURL) = try validatedDatabricksValues(profile: profile)
        let baseURL = workspaceURL.appending(path: "ai-gateway/codex/v1").absoluteString
        let tokenCommand = "databricks auth token --profile \(shellQuote(profileName)) --output json "
            + "| /usr/bin/plutil -extract access_token raw -o - -"
        let configuration = """
        model_provider = "databricks"

        [model_providers.databricks]
        name = "Databricks AI Gateway"
        base_url = "\(tomlEscape(baseURL))"
        wire_api = "responses"

        [model_providers.databricks.auth]
        command = "sh"
        args = ["-c", "\(tomlEscape(tokenCommand))"]
        timeout_ms = 5000
        refresh_interval_ms = 1800000

        [model_providers.databricks.http_headers]
        Databricks-Ai-Gateway-Request-Tags = "{\\\"source\\\": \\\"dahlia\\\"}"
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
