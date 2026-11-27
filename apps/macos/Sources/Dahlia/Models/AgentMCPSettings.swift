import DahliaRuntimeSupport
import Foundation

/// An MCP server the user registered for an account's chat. Unity AI Gateway servers share a provider.
struct AgentMCPServer: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    /// Pi's server name, which also prefixes its tools (`mcp__<name>__`).
    var name: String
    /// The sign-in the server uses. Optional for compatibility with retired local tools.
    let providerID: String?
    /// The fully qualified Unity AI Gateway service name; a directly configured server's own name.
    let service: String
    /// A server configured directly over stdio or HTTP, with no provider.
    var direct: AgentMCPDirectConfiguration?

    /// The service's last name part as Settings shows it: `Google Calendar` for `system.ai.google_calendar`.
    static func displayName(for service: String) -> String {
        let name = service.split(separator: ".").last ?? Substring(service)
        let displayNames = ["dbsql": "Databricks SQL", "genie_one_mcp": "Genie One", "sandbox": "Databricks Sandbox"]
        if let displayName = displayNames[name.lowercased()] { return displayName }
        let spellings = ["github": "GitHub", "dbsql": "DBSQL", "sql": "SQL", "mcp": "MCP", "ai": "AI"]
        return name
            .split(separator: "_")
            .map { spellings[$0.lowercased()] ?? $0.capitalized }
            .joined(separator: " ")
    }

    func url(workspaceURL: URL) -> URL {
        workspaceURL.appending(path: "ai-gateway/mcp-services/\(service)")
    }
}

/// A Unity AI Gateway, named by its workspace host. A Databricks connection in `provider_accounts` is one: the app
/// holds its sign-in and bridges its token. A workspace added before every connection was a provider account is one
/// too: Pi keeps its OAuth credential in `auth.json` under `id`, and the extension registers the providers that
/// `mcp.json` names.
struct AgentMCPProvider: Codable, Hashable, Identifiable, Sendable {
    /// The workspace host (with its port, if any), as the extension names the provider.
    let id: String
    /// The workspace origin. Settings shows its host to tell providers apart.
    let workspaceURL: URL

    // shortcut: every sign-in uses the extension's default client (the Databricks CLI's); pass `--client-id` to
    // `/databricks-login` again if an organization's own client is needed.
    init(workspaceURL: URL) {
        id = Self.id(for: workspaceURL)
        self.workspaceURL = workspaceURL
    }

    var host: String {
        workspaceURL.host() ?? workspaceURL.absoluteString
    }

    /// Whether it is a provider account: Dahlia holds its sign-in, so it never signs in or out through Pi.
    var isAccount: Bool {
        ProviderAccountDirectory.databricksConnections().contains { $0.piProviderID == id }
    }

    static func id(for workspaceURL: URL) -> String {
        (workspaceURL.host() ?? workspaceURL.absoluteString) + (workspaceURL.port.map { ":\($0)" } ?? "")
    }

    /// `/databricks-mcp-services`'s arguments: the account's workspace lists with the account's sign-in.
    var listingArguments: String {
        workspaceURL.absoluteString + (isAccount ? " --provider \(id)" : "")
    }
}

/// A directly configured MCP server, as other MCP clients' `mcpServers` entries: a stdio command or a streamable HTTP URL.
struct AgentMCPDirectConfiguration: Codable, Hashable, Sendable {
    enum Transport: String, Codable, CaseIterable, Sendable {
        case stdio, http
    }

    var transport: Transport = .stdio
    var isEnabled = true
    var command = ""
    var args: [String] = []
    var env: [String: String] = [:]
    var url = ""
    var headers: [String: String] = [:]

    /// The command or URL displayed in Settings.
    var endpoint: String {
        transport == .stdio ? ([command] + args).joined(separator: " ") : url
    }

    /// Why Pi could not start the server, or nil.
    var error: String? {
        switch transport {
        case .stdio:
            return command.trimmingCharacters(in: .whitespaces).isEmpty ? L10n.mcpDirectCommandRequired : nil
        case .http:
            if let endpoint = URL(string: url), let scheme = endpoint.scheme,
               ["http", "https"].contains(scheme.lowercased()), endpoint.host()?.isEmpty == false,
               endpoint.port.map({ (0 ... 65535).contains($0) }) ?? true { return nil }
            return L10n.mcpDirectURLInvalid
        }
    }

    static func parse(
        transport: Transport, command: String, arguments: [String], environment: [Pair], url: String, headers: [Pair]
    ) throws -> Self {
        guard let env = transport == .stdio ? pairs(environment) : [:],
              let headers = transport == .http ? pairs(headers) : [:]
        else { throw AgentMCPSettingsError(message: L10n.mcpDirectPairsInvalid) }
        return Self(
            transport: transport, command: command.trimmingCharacters(in: .whitespaces),
            args: arguments, env: env,
            url: url.trimmingCharacters(in: .whitespaces), headers: headers
        )
    }

    /// The `mcp.json` entry. Pi resolves `${VAR}` in `env` and `headers` from the chat's environment.
    var piEntry: JSONValue {
        var entry: [String: JSONValue] = ["exposure": .string("direct")]
        switch transport {
        case .stdio:
            entry["command"] = .string(command)
            entry["args"] = .array(args.map(JSONValue.string))
            if !env.isEmpty { entry["env"] = .object(env.mapValues(JSONValue.string)) }
        case .http:
            entry["url"] = .string(url)
            if !headers.isEmpty { entry["headers"] = .object(headers.mapValues(JSONValue.string)) }
        }
        return .object(entry)
    }

    typealias Pair = (key: String, value: String)

    /// Key and value rows as a dictionary, skipping empty rows, or nil when a row has no key or repeats one.
    static func pairs(_ rows: [Pair]) -> [String: String]? {
        var pairs: [String: String] = [:]
        for row in rows {
            let key = row.key.trimmingCharacters(in: .whitespaces)
            if key.isEmpty, row.value.isEmpty { continue }
            guard !key.isEmpty, pairs.updateValue(row.value, forKey: key) == nil else { return nil }
        }
        return pairs
    }
}

/// The MCP servers registered for one account, kept in app defaults. Gateway credentials are not stored here;
/// a directly configured server keeps its `env` and `headers` as entered (`${VAR}` keeps a secret out).
struct AgentMCPSettings: Codable, Equatable, Sendable {
    private static let removedProvidersKey = "agentMCPs.removedProviderAccounts"
    var providers: [AgentMCPProvider] = []
    var servers: [AgentMCPServer] = []
    /// Each provider's MCP services as last listed, keyed by provider ID, so Settings shows them before listing again.
    /// Optional so settings saved before it still decode.
    var listedServices: [String: [String]]?
    /// Descriptions from the last successful listing, keyed by provider ID and full service name.
    var serviceComments: [String: [String: String]]?
    /// Explicit full-name registrations remain visible even when disabled or absent from discovery.
    var manualServices: [String: [String]]?

    static func defaultsKey() -> String {
        "agentMCPs.\(AppAccount.key)"
    }

    static func load(defaults: UserDefaults = .standard) -> Self {
        var settings = defaults.data(forKey: defaultsKey()).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
        settings.servers.removeAll { $0.providerID == nil && $0.direct == nil && $0.service == "lightpanda" }
        if settings.manualServices == nil {
            let manual = (settings.listedServices ?? [:]).mapValues { $0.filter { !$0.hasPrefix("system.ai.") } }
                .filter { !$0.value.isEmpty }
            if !manual.isEmpty { settings.manualServices = manual }
        }
        settings.removeProviders(Set(defaults.stringArray(forKey: removedProvidersKey) ?? []))
        return settings
    }

    func save(defaults: UserDefaults = .standard) {
        // A settings window or in-flight listing may still hold a snapshot from before account removal.
        var current = self
        current.removeProviders(Set(defaults.stringArray(forKey: Self.removedProvidersKey) ?? []))
        defaults.set(try? JSONEncoder().encode(current), forKey: Self.defaultsKey())
    }

    /// Retires every registration before removing the app credential. Retained Pi auth stays inert, even if a stale
    /// settings snapshot is saved later. No Pi process or credential-file mutation is required.
    static func removeProviderAccount(_ id: String, agentURL: URL, defaults: UserDefaults = .standard) throws {
        var removed = Set(defaults.stringArray(forKey: removedProvidersKey) ?? [])
        removed.insert(id)
        defaults.set(removed.sorted(), forKey: removedProvidersKey)
        let settings = load(defaults: defaults)
        settings.save(defaults: defaults)
        guard FileManager.default.fileExists(atPath: agentURL.path) else { return }
        try PiProviderConfiguration.updateProviders(agentURL: agentURL) { $0[id] = nil }
        try PiProviderConfiguration.writeMCPServers([:], agentURL: agentURL)
    }

    /// An explicitly added service may use the host again after it has been connected as an app provider account.
    static func allowProviderAccount(_ id: String, defaults: UserDefaults = .standard) {
        let removed = (defaults.stringArray(forKey: removedProvidersKey) ?? []).filter { $0 != id }
        defaults.set(removed, forKey: removedProvidersKey)
    }

    private mutating func removeProviders(_ ids: Set<String>) {
        providers.removeAll { ids.contains($0.id) }
        servers.removeAll { $0.providerID.map(ids.contains) == true }
        for id in ids {
            listedServices?[id] = nil
            serviceComments?[id] = nil
            manualServices?[id] = nil
        }
    }

    func provider(id: String) -> AgentMCPProvider? {
        providers.first { $0.id == id }
    }

    /// Durable grants bind the registration and endpoint, never its reusable tool-name prefix.
    func connectionID(for name: String) -> String? {
        guard let server = servers.first(where: { $0.name == name }) else { return nil }
        if let direct = server.direct { return direct.isEnabled ? "\(server.id.uuidString)|direct" : nil }
        guard let providerID = server.providerID,
              let provider = provider(id: providerID) else { return nil }
        return "\(server.id.uuidString)|\(providerID)|\(server.url(workspaceURL: provider.workspaceURL).absoluteString)"
    }

    func serverName(for connectionID: String) -> String? {
        servers.first { self.connectionID(for: $0.name) == connectionID }?.name
    }

    var directConnectionIDs: [String: String] {
        servers.reduce(into: [:]) { result, server in
            if server.direct != nil { result[server.name] = connectionID(for: server.name) }
        }
    }

    var scheduledServers: Set<String> { Set(piServers.keys).union(["dahlia"]) }

    /// Legacy names can overlap tool prefixes. Refuse ambiguity rather than start an unapproved server.
    static func scheduledServer(for tool: String, servers: Set<String>) -> String? {
        let matches = servers.filter { tool.hasPrefix("mcp__\($0)__") }
        return matches.count == 1 ? matches.first : nil
    }

    /// Identity tokens stay alongside tool names in the existing schedule grant array.
    static func scheduledToolGrants(_ tools: [String], connections: [String: String], servers: Set<String>) -> [String] {
        let tools = tools.filter { scheduledServer(for: $0, servers: servers) != nil }
        return tools + tools.compactMap { tool in
            guard let server = scheduledServer(for: tool, servers: servers), let identity = connections[server] else { return nil }
            return "connection|\(tool)|\(identity)"
        }
    }

    func allowsScheduledTool(_ tool: String, grants: Set<String>) -> Bool {
        guard grants.contains(tool), Self.scheduledServer(for: tool, servers: scheduledServers) != nil else { return false }
        let prefix = "connection|\(tool)|"
        let approved = Set(grants.filter { $0.hasPrefix(prefix) })
        let expected = Set(Self.scheduledToolGrants([tool], connections: directConnectionIDs, servers: scheduledServers)
            .filter { $0.hasPrefix(prefix) })
        return approved == expected
    }

    func validateScheduledGrants(_ tools: [String]) throws {
        let grants = Set(tools)
        guard tools.filter({ $0.hasPrefix("mcp__") }).allSatisfy({ allowsScheduledTool($0, grants: grants) })
        else { throw HermesLearning.failure(L10n.mcpDirectConnectionChanged) }
    }

    /// Why `name` cannot name a new server, or nil. Internal server names cannot be overridden by gateway services.
    func nameError(_ name: String) -> String? {
        // `__` would make `mcp__a__b__c` match both servers `a` and `a__b`, so a scheduled run could start both.
        guard name.count <= 40, name.wholeMatch(of: /[a-z0-9_]+/) != nil, !name.contains("__") else { return L10n.mcpServerNameInvalid }
        guard name != "dahlia", name != AgentWebAccessSettings.serverName,
              !servers.contains(where: { $0.name == name }) else { return L10n.mcpServerNameTaken }
        return nil
    }

    /// The service's last name part made tool-safe (`github` for `system.ai.github`), numbered when a registered server
    /// or one of `taken` already has it.
    func defaultName(for service: String, taken: Set<String> = []) -> String {
        let base = Self.baseName(for: service)
        var name = base
        var number = 2
        while nameError(name) != nil || taken.contains(name) {
            name = base + (base.hasSuffix("_") ? "" : "_") + String(number)
            number += 1
        }
        return name
    }

    /// The service's last name part made tool-safe, before any number: `github` for `system.ai.github`.
    static func baseName(for service: String) -> String {
        let last = service.split(separator: ".").last.map(String.init) ?? service
        let safe = String(last.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" })
            .replacing(/_{2,}/, with: "_")
        return String(safe.prefix(36)).nilIfBlank ?? "mcp"
    }

    /// `mcp.json` entries keyed by server name. Gateway servers use `auth.provider`; a direct server's stdio command runs
    /// as Pi's child, outside the chat's Seatbelt, like Dahlia MCP.
    var piServers: [String: JSONValue] {
        servers.reduce(into: [:]) { entries, server in
            guard server.name != AgentWebAccessSettings.serverName else { return }
            if let direct = server.direct {
                if direct.isEnabled { entries[server.name] = direct.piEntry }
                return
            }
            guard let providerID = server.providerID, let provider = provider(id: providerID) else { return }
            entries[server.name] = .object([
                "url": .string(server.url(workspaceURL: provider.workspaceURL).absoluteString),
                "exposure": .string("direct"),
                "auth": .object(["provider": .string(provider.id)]),
            ])
        }
    }
}
