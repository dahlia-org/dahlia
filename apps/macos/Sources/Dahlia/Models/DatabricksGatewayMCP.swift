import DahliaRuntimeSupport
import Foundation

/// External-service MCPs in a Databricks workspace's Unity AI Gateway (`system.ai.<name>`). The user turns each on
/// per Databricks account; chat registers the enabled ones with Pi, which calls them with the account's Databricks token.
enum DatabricksGatewayMCP: String, CaseIterable, Identifiable, Sendable {
    case gmail
    case googleCalendar = "google_calendar"
    case googleDrive = "google_drive"
    case slack
    case github
    case atlassian
    case microsoft365 = "microsoft_365"

    var id: String { rawValue }

    /// Product names; they are not localized.
    var displayName: String {
        switch self {
        case .gmail: "Gmail"
        case .googleCalendar: "Google Calendar"
        case .googleDrive: "Google Drive"
        case .slack: "Slack"
        case .github: "GitHub"
        case .atlassian: "Atlassian (Jira, Confluence)"
        case .microsoft365: "Microsoft 365"
        }
    }

    func defaultsKey(connectionID: UUID) -> String {
        "databricksGatewayMCP.\(connectionID.uuidString.lowercased()).\(rawValue)"
    }

    static func enabled(connectionID: UUID, defaults: UserDefaults = .standard) -> [Self] {
        allCases.filter { defaults.bool(forKey: $0.defaultsKey(connectionID: connectionID)) }
    }

    /// `mcp.json` entries keyed by Pi server name (also the tool prefix `mcp__<name>__`). Each MCP on the workspace's
    /// gateway takes the Databricks provider's credential, the account's token, for every request.
    static func piServers(_ mcps: [Self], workspaceURL: URL) -> [String: JSONValue] {
        Dictionary(uniqueKeysWithValues: mcps.map { mcp in
            let url = workspaceURL.appending(path: "ai-gateway/mcp-services/system.ai.\(mcp.rawValue)")
            return (mcp.rawValue, .object([
                "url": .string(url.absoluteString),
                "exposure": .string("direct"),
                "auth": .object(["provider": .string(PiProviderConfiguration.databricksProviderIDs[0])]),
            ]))
        })
    }
}
