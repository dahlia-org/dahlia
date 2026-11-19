import Foundation

/// pi-web-access gives chat web search and page fetching. Its settings are the plugin's own `web-search.json` in the
/// account's agent directory, which chat's commands cannot read, like Pi's sign-ins beside it.
enum AgentWebAccessSettings {
    /// Installed from the Plugins tab. npm versions are immutable, so this pins the reviewed release.
    static let packageSource = "npm:pi-web-access@0.47.0"
    static let serverName = "dahlia_web_access"
    static let toolNames = ["web_search", "source_check", "fetch_content", "get_search_content"].map { "mcp__\(serverName)__\($0)" }
    /// The search providers whose keys the settings edit, under their `web-search.json` names.
    static let apiKeys: [(provider: String, key: String)] = [
        ("Exa", "exaApiKey"), ("Brave Search", "braveApiKey"), ("Tavily", "tavilyApiKey"),
        ("Perplexity", "perplexityApiKey"), ("Gemini", "geminiApiKey"), ("OpenAI", "openaiApiKey"),
        ("Jina", "jinaApiKey"), ("Firecrawl", "firecrawlApiKey"), ("Kagi", "kagiApiKey"), ("Parallel", "parallelApiKey"),
    ]

    struct Configuration: Equatable, Sendable {
        var webSearchEnabled = false
        var apiKeys: [String: String] = [:]
    }

    /// An npm source Pi installs at `entryURL`, whatever its version.
    static func isPackage(_ source: String) -> Bool {
        source == "npm:pi-web-access" || source.hasPrefix("npm:pi-web-access@")
    }

    /// The standalone MCP worker runs inside Seatbelt; no plugin code loads into Pi itself.
    static func entryURL(agentURL: URL) -> URL {
        agentURL.appending(path: "npm/node_modules/pi-web-access/dist/mcp-cli.js")
    }

    static func configURL(agentURL: URL) -> URL {
        agentURL.appending(path: "web-search.json")
    }

    /// A missing `webSearch.enabled` reads as off, as `writeDefault` then records it.
    static func load(agentURL: URL) throws -> Configuration {
        let object = try read(agentURL)
        let enabled = (object["webSearch"] as? [String: Any])?["enabled"] as? Bool ?? false
        let tools = object["tools"] as? [String: [String: Any]] ?? [:]
        return Configuration(
            webSearchEnabled: (tools["webSearch"]?["enabled"] as? Bool ?? enabled)
                || (tools["sourceCheck"]?["enabled"] as? Bool ?? enabled),
            apiKeys: apiKeys.reduce(into: [:]) { keys, entry in keys[entry.key] = object[entry.key] as? String }
        )
    }

    /// Keeps every other setting the user wrote in the file.
    static func save(_ configuration: Configuration, agentURL: URL) throws {
        var object = try read(agentURL)
        var webSearch = object["webSearch"] as? [String: Any] ?? [:]
        webSearch["enabled"] = configuration.webSearchEnabled
        object["webSearch"] = webSearch
        // Both search tools inherit the app toggle rather than retaining upstream overrides.
        if var tools = object["tools"] as? [String: [String: Any]] {
            for name in ["webSearch", "sourceCheck"] {
                tools[name]?.removeValue(forKey: "enabled")
            }
            object["tools"] = tools
        }
        for (_, key) in apiKeys {
            let value = configuration.apiKeys[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            object[key] = value.isEmpty ? nil : value
        }
        let url = configURL(agentURL: agentURL)
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// The plugin turns web search on when the setting is missing; Dahlia's default is off.
    static func writeDefault(agentURL: URL) throws {
        guard try !((read(agentURL)["webSearch"] as? [String: Any])?["enabled"] is Bool) else { return }
        var configuration = try load(agentURL: agentURL)
        configuration.webSearchEnabled = false
        try save(configuration, agentURL: agentURL)
    }

    private static func read(_ agentURL: URL) throws -> [String: Any] {
        let url = configURL(agentURL: agentURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
    }
}
