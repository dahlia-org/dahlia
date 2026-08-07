import DahliaRuntimeSupport
import Foundation

struct MCPRegistrationCommands: Equatable {
    private struct MCPJSONConfiguration: Encodable {
        let mcpServers: [String: MCPServer]
    }

    private struct MCPServer: Encodable {
        let command: String
        let args: [String]
        let env: [String: String]?
    }

    private let helperPath: String
    private let invocation: String
    private let runtimeProfile: DahliaRuntimeProfile
    private let vault: String
    private let vaultID: String

    init(
        helperURL: URL,
        vaultID: UUID,
        runtimeProfile: DahliaRuntimeProfile = DahliaApplicationSupport.profile()
    ) {
        helperPath = helperURL.path
        let helper = Self.shellQuote(helperURL.path)
        self.vaultID = vaultID.uuidString
        vault = Self.shellQuote(vaultID.uuidString)
        invocation = Self.helperInvocation(helper: helper, runtimeProfile: runtimeProfile)
        self.runtimeProfile = runtimeProfile
    }

    func registrationCommand(for client: MCPClient, writeEnabled: Bool) -> String {
        let writeArgument = writeEnabled ? " --write" : ""
        return "\(client.registrationCommandPrefix) \(invocation) --vault-id \(vault)\(writeArgument)"
    }

    func removalCommand(for client: MCPClient) -> String {
        client.removalCommand
    }

    func mcpJSONSample(writeEnabled: Bool) -> String? {
        var args = ["--vault-id", vaultID]
        if writeEnabled {
            args.append("--write")
        }

        let environment = runtimeProfile == .development
            ? [DahliaApplicationSupport.profileEnvironmentKey: DahliaRuntimeProfile.development.rawValue]
            : nil
        let configuration = MCPJSONConfiguration(
            mcpServers: [
                "dahlia": MCPServer(
                    command: helperPath,
                    args: args,
                    env: environment
                ),
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(configuration) else { return nil }
        return String(data: data, encoding: .utf8)
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
