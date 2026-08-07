import DahliaRuntimeSupport
import Foundation

struct MCPRegistrationCommands: Equatable {
    private let helperPath: String
    private let invocation: String
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

        guard let command = Self.jsonString(helperPath) else { return nil }
        let arguments = args.compactMap(Self.jsonString)
        guard arguments.count == args.count else { return nil }
        let formattedArguments = arguments.map { "        \($0)" }.joined(separator: ",\n")

        return """
        {
          "mcpServers": {
            "dahlia": {
              "command": \(command),
              "args": [
        \(formattedArguments)
              ]
            }
          }
        }
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

    private static func jsonString(_ value: String) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
