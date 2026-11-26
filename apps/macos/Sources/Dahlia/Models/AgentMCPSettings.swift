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
            command.trimmingCharacters(in: .whitespaces).isEmpty ? L10n.mcpDirectCommandRequired : nil
        case .http:
            URL(string: url).flatMap(\.scheme).map { ["http", "https"].contains($0.lowercased()) } == true ? nil : L10n.mcpDirectURLInvalid
        }
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

    /// `KEY<separator>value` lines as a dictionary, or nil when a non-empty line has no key.
    static func pairs(_ text: String, separator: Character) -> [String: String]? {
        var pairs: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let index = line.firstIndex(of: separator) else { return nil }
            let key = line[..<index].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return nil }
            pairs[key] = line[line.index(after: index)...].trimmingCharacters(in: .whitespaces)
        }
        return pairs
    }

    static func lines(_ pairs: [String: String], separator: String) -> String {
        pairs.sorted { $0.key < $1.key }.map { "\($0.key)\(separator)\($0.value)" }.joined(separator: "\n")
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
        try PiProviderConfiguration.writeMCPServers(settings.piServers, agentURL: agentURL)
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

    /// Why `name` cannot name a new server, or nil. Internal server names cannot be overridden by gateway services.
    func nameError(_ name: String) -> String? {
        guard name.count <= 40, name.wholeMatch(of: /[a-z0-9_]+/) != nil else { return L10n.mcpServerNameInvalid }
        guard name != "dahlia", name != AgentWebAccessSettings.serverName,
              !servers.contains(where: { $0.name == name }) else { return L10n.mcpServerNameTaken }
        return nil
    }

    /// The service's last name part made tool-safe (`github` for `system.ai.github`), numbered when a registered server
    /// or one of `taken` already has it.
    func defaultName(for service: String, taken: Set<String> = []) -> String {
        let last = service.split(separator: ".").last.map(String.init) ?? service
        let base = String(last.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" }.prefix(36)).nilIfBlank ?? "mcp"
        var name = base
        var number = 2
        while nameError(name) != nil || taken.contains(name) {
            name = "\(base)_\(number)"
            number += 1
        }
        return name
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
