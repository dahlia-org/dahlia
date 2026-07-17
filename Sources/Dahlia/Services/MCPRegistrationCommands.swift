import DahliaRuntimeSupport
import Foundation

struct MCPRegistrationCommands: Equatable {
    let codex: String
    let claude: String

    init(
        helperURL: URL,
        vaultID: UUID,
        runtimeProfile: DahliaRuntimeProfile = DahliaApplicationSupport.profile()
    ) {
        let helper = Self.shellQuote(helperURL.path)
        let vault = Self.shellQuote(vaultID.uuidString)
        let invocation = Self.helperInvocation(helper: helper, runtimeProfile: runtimeProfile)
        codex = """
        codex mcp remove dahlia
        codex mcp add dahlia -- \(invocation) --vault-id \(vault)
        """
        claude = """
        claude mcp remove --scope user dahlia
        claude mcp add --scope user dahlia -- \(invocation) --vault-id \(vault)
        """
    }

    private static func helperInvocation(helper: String, runtimeProfile: DahliaRuntimeProfile) -> String {
        guard runtimeProfile == .development else { return helper }
        let assignment = shellQuote(
            "\(DahliaApplicationSupport.profileEnvironmentKey)=\(DahliaRuntimeProfile.development.rawValue)"
        )
        return "/usr/bin/env \(assignment) \(helper)"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
