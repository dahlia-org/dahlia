enum MCPClient: String, CaseIterable, Identifiable {
    case claude
    case codex
    case mcpJSON

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex:
            L10n.codexCLI
        case .claude:
            L10n.claudeCode
        case .mcpJSON:
            L10n.mcpOtherApps
        }
    }

    var registrationCommandPrefix: String? {
        switch self {
        case .codex:
            "codex mcp add dahlia --"
        case .claude:
            "claude mcp add --scope user dahlia --"
        case .mcpJSON:
            nil
        }
    }

    var removalCommand: String? {
        switch self {
        case .codex:
            "codex mcp remove dahlia"
        case .claude:
            "claude mcp remove --scope user dahlia"
        case .mcpJSON:
            nil
        }
    }
}
