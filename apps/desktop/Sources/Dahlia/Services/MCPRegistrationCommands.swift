import DahliaRuntimeSupport
import Foundation

struct MCPRegistrationCommands: Equatable {
    private let helper: String
    private let helperPath: String
    private let vault: String?
    private let vaultID: String?

    init(
        helperURL: URL,
        vaultID: UUID?
    ) {
        helperPath = helperURL.path
        helper = Self.shellQuote(helperURL.path)
        self.vaultID = vaultID.map { TypeID.encode($0, as: .vault) }
        vault = vaultID.map { Self.shellQuote(TypeID.encode($0, as: .vault)) }
    }

    func registrationCommand(for client: MCPClient, writeEnabled: Bool) -> String? {
        guard let prefix = client.registrationCommandPrefix, !writeEnabled || vault != nil else { return nil }
        let writeArgument = writeEnabled ? " --write" : ""
        return "\(prefix) \(helper)\(vault.map { " --vault-id \($0)" } ?? "")\(writeArgument)"
    }

    func removalCommand(for client: MCPClient) -> String? {
        client.removalCommand
    }

    func mcpJSONSample(writeEnabled: Bool) -> String? {
        guard !writeEnabled || vaultID != nil else { return nil }
        var args = vaultID.map { ["--vault-id", $0] } ?? []
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
