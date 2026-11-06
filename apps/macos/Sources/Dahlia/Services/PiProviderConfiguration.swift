import DahliaRuntimeSupport
import Foundation

/// A subscription the Local Account signs in to through Pi's own OAuth flow. Several can be signed in at once.
enum PiSubscription: String, CaseIterable, Identifiable, Sendable {
    case openai
    case anthropic

    var id: String { rawValue }

    /// Pi's names for these sign-ins.
    var displayName: String {
        switch self {
        case .openai: "OpenAI (ChatGPT subscription)"
        case .anthropic: "Anthropic (Claude Pro/Max)"
        }
    }
}

extension CodexRuntimeProvider {
    /// Pi provider IDs whose models Dahlia offers for this account. Pi lists only those with credentials.
    var piProviderIDs: [String] {
        switch self {
        case .local: PiSubscription.allCases.map(\.rawValue)
        case .databricks: PiProviderConfiguration.databricksProviderIDs
        case .dahlia: ["dahlia"]
        }
    }

    /// Providers whose bearer token Dahlia supplies for each request through the extension bridge.
    var piBridgedProviderIDs: [String] {
        switch self {
        case .local: []
        case .databricks, .dahlia: piProviderIDs
        }
    }
}

/// Writes the account's `models.json`. Subscription providers use Pi's built-in catalog.
enum PiProviderConfiguration {
    static let databricksProviderIDs = ["databricks"]

    /// Placeholder key that marks the provider configured; the extension replaces the Authorization header.
    private static let bridgedAPIKey = "dahlia"

    static func write(_ providers: [String: JSONValue], agentURL: URL) throws {
        let data = try JSONEncoder().encode(JSONValue.object(["providers": .object(providers)]))
        let url = agentURL.appending(path: "models.json")
        guard FileManager.default.contents(atPath: url.path) != data else { return }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func databricksProviders(workspaceURL: URL) throws -> [String: JSONValue] {
        let data = try Data(contentsOf: PiBundle.resourceURL("databricks-models.json"))
        guard case let .object(catalog) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw CodexAppServerError.invalidProtocolResponse
        }
        let origin = workspaceURL.absoluteString
        // One `databricks` provider; each model names its gateway route (Anthropic, codex, MLflow, or Gemini).
        return catalog.compactMapValues { value in
            guard case var .object(provider) = value, let models = provider["models"]?.arrayValue else { return nil }
            provider["models"] = .array(models.compactMap { model in
                guard case var .object(model) = model, let path = model["baseUrl"]?.stringValue else { return nil }
                model["baseUrl"] = .string(origin + path)
                return .object(model)
            })
            provider["apiKey"] = .string(bridgedAPIKey)
            provider["authHeader"] = .bool(true)
            provider["headers"] = .object(["Databricks-Ai-Gateway-Request-Tags": .string(#"{"source": "dahlia"}"#)])
            return .object(provider)
        }
    }

    /// The Dahlia Server URL recorded in the account's `models.json`, if any.
    static func dahliaBaseURL(agentURL: URL) -> URL? {
        guard let data = FileManager.default.contents(atPath: agentURL.appending(path: "models.json").path),
              let provider = (try? JSONDecoder().decode(JSONValue.self, from: data))?
              .objectValue?["providers"]?.objectValue?["dahlia"]?.objectValue,
              let baseURL = provider["baseUrl"]?.stringValue
        else { return nil }
        return URL(string: baseURL)
    }

    static func fetchDahliaCatalog(baseURL: URL, token: String) async throws -> JSONValue {
        var request = URLRequest(url: baseURL.appending(path: "models"), timeoutInterval: 30)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw CodexConfigurationError.updateFailed(L10n.dahliaServerNotConfigured)
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Converts the Dahlia Server's Codex-style model catalog into one Pi provider.
    static func dahliaProvider(baseURL: URL, catalog: JSONValue) throws -> [String: JSONValue] {
        guard let entries = catalog.objectValue?["data"]?.arrayValue else {
            throw CodexAppServerError.invalidProtocolResponse
        }
        let definitions = Dictionary(
            (catalog.objectValue?["models"]?.arrayValue ?? []).compactMap { value -> (String, [String: JSONValue])? in
                guard let model = value.objectValue, let slug = model["slug"]?.stringValue else { return nil }
                return (slug, model)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let models: [JSONValue] = entries.compactMap { entry in
            guard let id = entry.objectValue?["id"]?.stringValue else { return nil }
            let definition = definitions[id] ?? [:]
            let efforts = Set((definition["supported_reasoning_levels"]?.arrayValue ?? []).compactMap {
                $0.objectValue?["effort"]?.stringValue
            })
            let modalities = definition["input_modalities"]?.arrayValue?.compactMap(\.stringValue) ?? ["text", "image"]
            var model: [String: JSONValue] = [
                "id": .string(id),
                "name": .string(entry.objectValue?["display_name"]?.stringValue ?? id),
                "reasoning": .bool(!efforts.isEmpty),
                "input": .array(modalities.filter { $0 == "text" || $0 == "image" }.map(JSONValue.string)),
                "contextWindow": .number(Double(definition["context_window"]?.intValue ?? 272_000)),
                "maxTokens": .number(128_000),
                "cost": .object(["input": .number(0), "output": .number(0), "cacheRead": .number(0), "cacheWrite": .number(0)]),
            ]
            if !efforts.isEmpty {
                var levels: [String: JSONValue] = ["off": efforts.contains("none") ? .string("none") : .null]
                for level in ["minimal", "low", "medium", "high", "xhigh", "max"] {
                    levels[level] = efforts.contains(level) ? .string(level) : .null
                }
                model["thinkingLevelMap"] = .object(levels)
            }
            return .object(model)
        }
        return ["dahlia": .object([
            "name": .string("Dahlia"),
            "baseUrl": .string(baseURL.absoluteString),
            "api": .string("openai-responses"),
            "apiKey": .string(bridgedAPIKey),
            "authHeader": .bool(true),
            "models": .array(models),
        ])]
    }

    /// Reasoning levels Pi accepts for a model object from `get_available_models`. Pi's `off` keeps Codex's
    /// name `none`, so saved settings still match; `PiRuntimeService.thinkingLevel` maps it back.
    static func reasoningEfforts(model: [String: JSONValue]) -> [String] {
        guard model["reasoning"]?.boolValue == true else { return [] }
        let map = model["thinkingLevelMap"]?.objectValue ?? [:]
        return ["off", "minimal", "low", "medium", "high", "xhigh", "max"].filter { level in
            if let value = map[level] { return value != .null }
            // Pi exposes xhigh and max only when the model maps them.
            return level != "xhigh" && level != "max"
        }.map { $0 == "off" ? "none" : $0 }
    }

    static func codexModel(_ model: [String: JSONValue]) -> CodexModel? {
        guard let id = model["id"]?.stringValue, let provider = model["provider"]?.stringValue else { return nil }
        let efforts = reasoningEfforts(model: model)
        let reference = "\(provider)/\(id)"
        return CodexModel(
            id: reference,
            model: reference,
            displayName: model["name"]?.stringValue ?? id,
            description: "",
            hidden: false,
            isDefault: false,
            supportedReasoningEfforts: efforts.map { CodexReasoningEffortOption(reasoningEffort: $0, description: "") },
            defaultReasoningEffort: efforts.contains(CodexReasoningEffortOption.defaultValue)
                ? CodexReasoningEffortOption.defaultValue
                : efforts.last ?? CodexReasoningEffortOption.defaultValue,
            inputModalities: model["input"]?.arrayValue?.compactMap(\.stringValue)
        )
    }
}
