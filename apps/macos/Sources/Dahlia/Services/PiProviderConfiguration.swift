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

    /// Providers whose credential is the account's token, which the extension resolves through the bridge for each use.
    var piBridgedProviderIDs: [String] {
        switch self {
        case .local: []
        case .databricks, .dahlia: piProviderIDs
        }
    }
}

/// Writes the account's `models.json` and `mcp.json`. Subscription providers use Pi's built-in catalog.
enum PiProviderConfiguration {
    static let databricksProviderIDs = ["databricks"]
    /// Whether a Pi provider ID names a workspace added in Agents settings: its host, the only provider IDs with a dot
    /// (Pi's own and Dahlia's, such as `openai` and `databricks`, have none; Agents settings refuses dotless hosts).
    static func isAddedWorkspace(_ providerID: some StringProtocol) -> Bool {
        providerID.contains(".")
    }

    /// The one model a Databricks account starts with, and its summary and image analysis default.
    static let databricksDefaultModel = "databricks/system.ai.claude-haiku-5-5"

    /// Writes these providers to `models.json`, keeping the others (such as the workspaces added in Agents settings).
    static func write(_ providers: [String: JSONValue], agentURL: URL) throws {
        try updateProviders(agentURL: agentURL) { $0.merge(providers) { $1 } }
    }

    static func updateProviders(agentURL: URL, _ change: (inout [String: JSONValue]) -> Void) throws {
        var providers = recordedProviders(agentURL: agentURL)
        change(&providers)
        try write(.object(["providers": .object(providers)]), to: agentURL.appending(path: "models.json"))
    }

    /// The account's MCP servers for Pi. They hold no credentials; an entry's `auth.provider` takes a bridged provider's.
    static func writeMCPServers(_ servers: [String: JSONValue], agentURL: URL) throws {
        try write(.object(["mcpServers": .object(servers)]), to: agentURL.appending(path: "mcp.json"))
    }

    private static func write(_ value: JSONValue, to url: URL) throws {
        // Sorted keys keep the providers' order, and so Pi's model list, the same for the same content.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(value)
        guard FileManager.default.contents(atPath: url.path) != data else { return }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// A Unity AI Gateway model that Pi can run, as Agents settings lists it. Only the models turned on go to
    /// `models.json`, which has no per-model switch of its own.
    struct DatabricksModel: Equatable, Sendable {
        /// The Pi provider: the account's own `databricks`, or a workspace added in Agents settings, by host.
        let providerID: String
        let id: String
        let name: String
        /// Every model starts off except the account's own gateway's `onByDefault` one (its first model when the gateway
        /// does not serve that one, so a Databricks account starts with a model); the account's choice wins.
        var isOnByDefault: Bool
        /// The Pi model entry.
        let definition: [String: JSONValue]

        /// How Pi and the saved settings name the model.
        var reference: String {
            "\(providerID)/\(id)"
        }

        func isOn(_ choices: [String: Bool]) -> Bool {
            choices[reference] ?? isOnByDefault
        }
    }

    /// The gateway's models built from the bundled `databricks-models.json`. `services` is the gateway's model list
    /// from Unity Catalog (`PiRuntimeService.modelServices`, saved by `saveGatewayServices`); without it, before the gateway first
    /// answers, the bundled `models` stand in.
    ///
    /// A model's fields are its generated name, then every template whose `match` glob fits its name without
    /// `system.ai.` in file order, then the image input the gateway reports, then its own `models` entry; each replaces
    /// whole top-level fields. A model needs a route (`baseUrl`) whose `gatewayApi` the service serves. The list follows
    /// the first matching template, then the `models` order, then the ID in descending numeric order.
    /// A workspace added in Agents settings names its models with its host's first label, since another gateway can
    /// serve the same model.
    static func databricksModels(
        workspaceURL: URL,
        services: [JSONValue]? = nil,
        providerID: String = databricksProviderIDs[0]
    ) throws -> [DatabricksModel] {
        let data = try Data(contentsOf: PiBundle.resourceURL("databricks-models.json"))
        guard let catalog = try JSONDecoder().decode(JSONValue.self, from: data).objectValue,
              let templates = catalog["templates"]?.arrayValue?.compactMap(\.objectValue),
              let entries = catalog["models"]?.arrayValue?.compactMap(\.objectValue)
        else { throw CodexAppServerError.invalidProtocolResponse }
        let listed = entries.compactMap { $0["id"]?.stringValue }
        let overrides = Dictionary(zip(listed, entries), uniquingKeysWith: { first, _ in first })
        let order = Dictionary(zip(listed, listed.indices), uniquingKeysWith: { first, _ in first })
        let available: [(id: String, apiTypes: Set<String>?, imageInput: Bool?)] = services?.compactMap { value in
            guard let service = value.objectValue, let name = service["name"]?.stringValue?.split(separator: "/").last,
                  // Pi's agent calls tools.
                  service["capabilities"]?.objectValue?["function_calling"]?.boolValue != false
            else { return nil }
            return (
                String(name),
                // A service that leaves its API types out serves any route, as one that leaves out `function_calling` calls tools.
                service["supported_api_types"]?.arrayValue.map { Set($0.compactMap(\.stringValue)) },
                service["capabilities"]?.objectValue?["image_input"]?.boolValue
            )
        } ?? listed.map { ($0, nil, nil) }

        let origin = workspaceURL.absoluteString
        var models = available.compactMap { service -> (rank: Int, model: DatabricksModel)? in
            let name = String(service.id.split(separator: ".").last ?? "")
            let matching = templates.indices.filter { templates[$0]["match"]?.stringValue.map { fnmatch($0, name, 0) == 0 } == true }
            guard let rank = matching.first else { return nil }
            var model: [String: JSONValue] = ["id": .string(service.id), "name": .string(displayName(name))]
            for index in matching {
                model.merge(templates[index]) { $1 }
            }
            if let imageInput = service.imageInput {
                model["input"] = .array(imageInput ? [.string("text"), .string("image")] : [.string("text")])
            }
            model.merge(overrides[service.id] ?? [:]) { $1 }
            guard let route = model["baseUrl"]?.stringValue,
                  let gatewayAPI = model["gatewayApi"]?.stringValue,
                  service.apiTypes?.contains(gatewayAPI) ?? true
            else { return nil }
            let isOnByDefault = providerID == databricksProviderIDs[0] && model["onByDefault"]?.boolValue == true
            let modelName = model["name"]?.stringValue ?? service.id
            if providerID != databricksProviderIDs[0] {
                model["name"] = .string("\(modelName) (\(workspaceURL.host()?.split(separator: ".").first ?? ""))")
            }
            model["baseUrl"] = .string(origin + route)
            for key in ["match", "gatewayApi", "onByDefault"] {
                model[key] = nil
            }
            return (rank, DatabricksModel(
                providerID: providerID,
                id: service.id,
                name: modelName,
                isOnByDefault: isOnByDefault,
                definition: model
            ))
        }.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            let (left, right) = (order[lhs.model.id] ?? .max, order[rhs.model.id] ?? .max)
            if left != right { return left < right }
            return lhs.model.id.compare(rhs.model.id, options: .numeric) == .orderedDescending
        }.map(\.model)
        if providerID == databricksProviderIDs[0], !models.isEmpty, !models.contains(where: \.isOnByDefault) {
            models[0].isOnByDefault = true
        }
        return models
    }

    /// The account's choices with its own gateway kept usable: when none of that gateway's listed models is on (the
    /// gateway stopped serving the one the account kept on), its default comes back on. Agents settings and
    /// `models.json` read the same result.
    static func effectiveChoices(_ choices: [String: Bool], for models: [DatabricksModel]) -> [String: Bool] {
        guard models.first?.providerID == databricksProviderIDs[0], !models.contains(where: { $0.isOn(choices) }),
              let fallback = models.first(where: \.isOnByDefault) ?? models.first
        else { return choices }
        return choices.merging([fallback.reference: true]) { $1 }
    }

    /// A Unity AI Gateway provider with the models the account keeps on: the account's own `databricks`, whose
    /// credential is bridged, or a workspace added in Agents settings, whose OAuth sign-in Pi keeps. Each model names its
    /// gateway route (Anthropic, codex, MLflow, or Gemini); the provider's `baseUrl` records the workspace.
    static func databricksProviders(
        _ models: [DatabricksModel],
        choices: [String: Bool],
        workspaceURL: URL,
        providerID: String = databricksProviderIDs[0]
    ) -> [String: JSONValue] {
        [providerID: .object([
            "name": .string(providerID == databricksProviderIDs[0] ? "Databricks" : providerID),
            "baseUrl": .string(workspaceURL.absoluteString),
            "authHeader": .bool(true),
            "headers": .object(["Databricks-Ai-Gateway-Request-Tags": .string(#"{"source": "dahlia"}"#)]),
            "models": .array(models.filter { $0.isOn(effectiveChoices(choices, for: models)) }.map { .object($0.definition) }),
        ])]
    }

    /// `claude-opus-5-5` reads `Claude Opus 5.5`, and `kimi-k3-1-pro` reads `Kimi K3.1 Pro`.
    static func displayName(_ name: String) -> String {
        name.split(separator: "-").reduce(into: [String]()) { words, part in
            if part.allSatisfy(\.isNumber), let last = words.last, last.last?.isNumber == true {
                words[words.count - 1] += "." + part
            } else {
                words.append(["gpt", "glm"].contains(part) ? part.uppercased() : part.prefix(1).uppercased() + part.dropFirst())
            }
        }.joined(separator: " ")
    }

    /// Each Unity AI Gateway's model services as it last answered, by provider ID: the source `models.json` is built
    /// from, so activation and model switches need no network. Kept beside `models.json` in the account's directory.
    static func gatewayServices(agentURL: URL) -> [String: [JSONValue]] {
        guard let data = FileManager.default.contents(atPath: agentURL.appending(path: "gateway-models.json").path),
              let saved = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue
        else { return [:] }
        return saved.compactMapValues(\.arrayValue)
    }

    /// Saves a gateway's answer, unless it yields no model Pi can run (nothing listed, or only services the templates
    /// cannot route): the saved list, or before it the bundled stand-in, keeps serving, so an answer from a sign-in that
    /// cannot browse `system.ai` never leaves the account with no model.
    static func saveGatewayServices(_ services: [JSONValue], providerID: String, agentURL: URL) throws {
        guard let probe = URL(string: "https://\(providerID)"),
              try !databricksModels(workspaceURL: probe, services: services, providerID: providerID).isEmpty
        else { return }
        var saved = gatewayServices(agentURL: agentURL)
        saved[providerID] = services
        try write(.object(saved.mapValues(JSONValue.array)), to: agentURL.appending(path: "gateway-models.json"))
    }

    /// The workspace recorded in the account's `models.json`, if any.
    static func databricksWorkspaceURL(agentURL: URL) -> URL? {
        recordedProvider("databricks", agentURL: agentURL)?["baseUrl"]?.stringValue.flatMap(URL.init(string:))
    }

    /// The Dahlia Server URL recorded in the account's `models.json`, if any.
    static func dahliaBaseURL(agentURL: URL) -> URL? {
        recordedProvider("dahlia", agentURL: agentURL)?["baseUrl"]?.stringValue.flatMap(URL.init(string:))
    }

    private static func recordedProvider(_ id: String, agentURL: URL) -> [String: JSONValue]? {
        recordedProviders(agentURL: agentURL)[id]?.objectValue
    }

    private static func recordedProviders(agentURL: URL) -> [String: JSONValue] {
        guard let data = FileManager.default.contents(atPath: agentURL.appending(path: "models.json").path) else { return [:] }
        return (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue?["providers"]?.objectValue ?? [:]
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
