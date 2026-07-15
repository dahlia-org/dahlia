import Foundation

struct MCPRegistrationCommands: Equatable {
    let codex: String
    let claude: String

    init(helperURL: URL, vaultID: UUID) {
        let helper = Self.shellQuote(helperURL.path)
        let vault = Self.shellQuote(vaultID.uuidString)
        codex = """
        codex mcp remove dahlia
        codex mcp add dahlia -- \(helper) --vault-id \(vault)
        """
        claude = """
        claude mcp remove --scope user dahlia
        claude mcp add --scope user dahlia -- \(helper) --vault-id \(vault)
        """
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
