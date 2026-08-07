import DahliaRuntimeSupport
import Foundation

struct MCPRegistrationCommands: Equatable {
    private let invocation: String
    private let vault: String

    init(
        helperURL: URL,
        vaultID: UUID,
        runtimeProfile: DahliaRuntimeProfile = DahliaApplicationSupport.profile()
    ) {
        let helper = Self.shellQuote(helperURL.path)
        let vault = Self.shellQuote(vaultID.uuidString)
        invocation = Self.helperInvocation(helper: helper, runtimeProfile: runtimeProfile)
        self.vault = vault
    }

    func registrationCommand(for client: MCPClient, writeEnabled: Bool) -> String {
        let writeArgument = writeEnabled ? " --write" : ""
        return "\(client.registrationCommandPrefix) \(invocation) --vault-id \(vault)\(writeArgument)"
    }

    func removalCommand(for client: MCPClient) -> String {
        client.removalCommand
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
