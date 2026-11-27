import Foundation

extension AgentMCPDirectConfiguration {
    private static let maximumJSONBytes = 64 * 1024

    private static func validateJSONSize(_ byteCount: Int) throws {
        guard byteCount <= maximumJSONBytes else { throw AgentMCPSettingsError(message: L10n.mcpDirectJSONTooLarge) }
    }

    /// Standard MCP fields only. App enablement and registration identity stay outside the imported JSON.
    private struct JSONEntry: Codable {
        var type: String?
        var command: String?
        var args: [String]?
        var env: [String: String]?
        var url: String?
        var headers: [String: String]?
    }

    func jsonString() throws -> String {
        let entry = JSONEntry(
            type: transport.rawValue, command: transport == .stdio ? command : nil,
            args: transport == .stdio ? args : nil, env: transport == .stdio && !env.isEmpty ? env : nil,
            url: transport == .http ? url : nil, headers: transport == .http && !headers.isEmpty ? headers : nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(entry)
        try Self.validateJSONSize(data.count)
        return String(decoding: data, as: UTF8.self)
    }

    static func parseJSON(_ text: String) throws -> (name: String?, configuration: Self) {
        do {
            try validateJSONSize(text.utf8.prefix(maximumJSONBytes + 1).count)
            guard var object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                throw AgentMCPSettingsError(message: L10n.mcpDirectJSONInvalid)
            }
            var name: String?
            if let servers = object["mcpServers"] {
                guard object.count == 1, let entries = servers as? [String: Any] else {
                    throw AgentMCPSettingsError(message: L10n.mcpDirectJSONInvalid)
                }
                object = entries
            }
            if object.count == 1, let entry = object.first, let configuration = entry.value as? [String: Any] {
                name = entry.key
                object = configuration
            }
            guard Set(object.keys).isSubset(of: ["type", "command", "args", "env", "url", "headers"]) else {
                throw AgentMCPSettingsError(message: L10n.mcpDirectJSONInvalid)
            }
            let entry = try JSONDecoder().decode(JSONEntry.self, from: JSONSerialization.data(withJSONObject: object))
            guard let transport = Transport(rawValue: entry.type ?? (entry.url == nil ? "stdio" : "http")) else {
                throw AgentMCPSettingsError(message: L10n.mcpDirectJSONInvalid)
            }
            let mixedTransport = transport == .stdio
                ? entry.url != nil || entry.headers != nil
                : entry.command != nil || entry.args != nil || entry.env != nil
            let hasEndpoint = transport == .stdio ? entry.command != nil : entry.url != nil
            guard !mixedTransport, hasEndpoint else { throw AgentMCPSettingsError(message: L10n.mcpDirectJSONInvalid) }
            let configuration = try parse(
                transport: transport, command: entry.command ?? "", arguments: entry.args ?? [],
                environment: (entry.env ?? [:]).map { ($0.key, $0.value) },
                url: entry.url ?? "", headers: (entry.headers ?? [:]).map { ($0.key, $0.value) }
            )
            // Keep incomplete drafts switchable, like the form; saveDirectServer validates the endpoint.
            return (name, configuration)
        } catch let error as AgentMCPSettingsError {
            throw error
        } catch {
            throw AgentMCPSettingsError(message: L10n.mcpDirectJSONInvalid)
        }
    }
}
