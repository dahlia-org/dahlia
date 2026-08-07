enum MCPClient: String, CaseIterable, Identifiable {
    case codex
    case claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex:
            L10n.codexCLI
        case .claude:
            L10n.claudeCode
        }
    }

    var registrationCommandPrefix: String {
        switch self {
        case .codex:
            "codex mcp add dahlia --"
        case .claude:
            "claude mcp add --scope user dahlia --"
        }
    }

    var removalCommand: String {
        switch self {
        case .codex:
            "codex mcp remove dahlia"
        case .claude:
            "claude mcp remove --scope user dahlia"
        }
    }
}
