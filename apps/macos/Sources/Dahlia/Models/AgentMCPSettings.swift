import DahliaRuntimeSupport
import Foundation

/// An MCP server the user registered for an account's chat. Unity AI Gateway servers share a provider.
struct AgentMCPServer: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    /// Pi's server name, which also prefixes its tools (`mcp__<name>__`).
    var name: String
    /// The sign-in the server uses. Optional for compatibility with retired local tools.
    let providerID: String?
    /// The fully qualified Unity AI Gateway service name.
    let service: String

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

/// A Unity AI Gateway sign-in. Pi keeps its OAuth credential, with the workspace and client, in the account's
/// `auth.json` under `id`; the extension registers the providers that `mcp.json` names. The account's own workspace,
/// whose models the account uses, is one too: its servers take the account's bridged sign-in instead.
struct AgentMCPProvider: Codable, Hashable, Identifiable, Sendable {
    /// The workspace host (with its port, if any), as the extension names the provider, or the account's bridged
    /// provider for the account's own workspace.
    let id: String
    /// The workspace origin. Settings shows its host to tell providers apart.
    let workspaceURL: URL

    // shortcut: every sign-in uses the extension's default client (the Databricks CLI's); pass `--client-id` to
    // `/databricks-login` again if an organization's own client is needed.
    init(workspaceURL: URL) {
        id = Self.id(for: workspaceURL)
        self.workspaceURL = workspaceURL
    }

    /// The Databricks account's own workspace. Dahlia holds its sign-in, so it never signs in or out here.
    static func account(workspaceURL: URL) -> Self {
        Self(id: PiProviderConfiguration.databricksProviderIDs[0], workspaceURL: workspaceURL)
    }

    private init(id: String, workspaceURL: URL) {
        self.id = id
        self.workspaceURL = workspaceURL
    }

    var host: String {
        workspaceURL.host() ?? workspaceURL.absoluteString
    }

    var isAccount: Bool {
        id == PiProviderConfiguration.databricksProviderIDs[0]
    }

    static func id(for workspaceURL: URL) -> String {
        (workspaceURL.host() ?? workspaceURL.absoluteString) + (workspaceURL.port.map { ":\($0)" } ?? "")
    }

    /// `/databricks-mcp-services`'s arguments: the account's workspace lists with the account's sign-in.
    var listingArguments: String {
        workspaceURL.absoluteString + (isAccount ? " --provider \(id)" : "")
    }
}

/// The MCP servers registered for one account, kept in app defaults. Credentials are not stored here.
struct AgentMCPSettings: Codable, Equatable, Sendable {
    var providers: [AgentMCPProvider] = []
    var servers: [AgentMCPServer] = []
    /// Each provider's MCP services as last listed, keyed by provider ID, so Settings shows them before listing again.
    /// Optional so settings saved before it still decode.
    var listedServices: [String: [String]]?
    /// Descriptions from the last successful listing, keyed by provider ID and full service name.
    var serviceComments: [String: [String: String]]?
    /// Explicit full-name registrations remain visible even when disabled or absent from discovery.
    var manualServices: [String: [String]]?

    static func defaultsKey(for account: CodexRuntimeProvider) -> String {
        "agentMCPs.\(account.accountKey)"
    }

    static func load(for account: CodexRuntimeProvider, defaults: UserDefaults = .standard) -> Self {
        var settings = defaults.data(forKey: defaultsKey(for: account)).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
        settings.servers.removeAll { $0.providerID == nil && $0.service == "lightpanda" }
        if settings.manualServices == nil {
            let manual = (settings.listedServices ?? [:]).mapValues { $0.filter { !$0.hasPrefix("system.ai.") } }
                .filter { !$0.value.isEmpty }
            if !manual.isEmpty { settings.manualServices = manual }
        }
        return settings
    }

    func save(for account: CodexRuntimeProvider, defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey(for: account))
    }

    func provider(id: String) -> AgentMCPProvider? {
        providers.first { $0.id == id }
    }

    /// Why `name` cannot name a new server, or nil. Tool names allow these characters; `dahlia` is Dahlia's own server.
    func nameError(_ name: String) -> String? {
        guard name.count <= 40, name.wholeMatch(of: /[a-z0-9_]+/) != nil else { return L10n.mcpServerNameInvalid }
        guard name != "dahlia", !servers.contains(where: { $0.name == name }) else { return L10n.mcpServerNameTaken }
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

    /// `mcp.json` entries keyed by server name. Gateway servers use `auth.provider`.
    var piServers: [String: JSONValue] {
        servers.reduce(into: [:]) { entries, server in
            guard let providerID = server.providerID, let provider = provider(id: providerID) else { return }
            entries[server.name] = .object([
                "url": .string(server.url(workspaceURL: provider.workspaceURL).absoluteString),
                "exposure": .string("direct"),
                "auth": .object(["provider": .string(provider.id)]),
            ])
        }
    }
}
