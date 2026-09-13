import DahliaRuntimeSupport
import Foundation

struct MCPRegistrationCommands: Equatable {
    private let helper: String
    private let helperPath: String
    private let workspace: String?
    private let workspaceID: String?

    init(
        helperURL: URL,
        workspaceID: UUID?
    ) {
        helperPath = helperURL.path
        helper = Self.shellQuote(helperURL.path)
        self.workspaceID = workspaceID.map { TypeID.encode($0, as: .workspace) }
        workspace = workspaceID.map { Self.shellQuote(TypeID.encode($0, as: .workspace)) }
    }

    func registrationCommand(for client: MCPClient, writeEnabled: Bool) -> String? {
        guard let prefix = client.registrationCommandPrefix else { return nil }
        let writeArgument = writeEnabled ? " --write" : ""
        return "\(prefix) \(helper)\(workspace.map { " --workspace-id \($0)" } ?? "")\(writeArgument)"
    }

    func removalCommand(for client: MCPClient) -> String? {
        client.removalCommand
    }

    func mcpJSONSample(writeEnabled: Bool) -> String? {
        var args = workspaceID.map { ["--workspace-id", $0] } ?? []
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
