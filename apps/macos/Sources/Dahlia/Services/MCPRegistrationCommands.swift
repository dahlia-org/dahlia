import DahliaRuntimeSupport
import Foundation

struct MCPRegistrationCommands: Equatable {
    private let helper: String
    private let helperPath: String
    private let runtimeProfile: DahliaRuntimeProfile
    private let scope: MCPAccessScope

    init(
        helperURL: URL,
        scope: MCPAccessScope,
        runtimeProfile: DahliaRuntimeProfile = DahliaApplicationSupport.profile()
    ) {
        helperPath = helperURL.path
        helper = Self.shellQuote(helperURL.path)
        self.runtimeProfile = runtimeProfile
        self.scope = scope
    }

    func registrationCommand(for client: MCPClient, writeEnabled: Bool) -> String? {
        guard let prefix = client.registrationCommandPrefix else { return nil }
        let writeArgument = writeEnabled ? " --write" : ""
        let command = runtimeProfile == .development
            ? "/usr/bin/env \(DahliaApplicationSupport.profileEnvironmentKey)=development \(helper)"
            : helper
        let scopeArguments = scope.arguments.map { $0.hasPrefix("--") ? $0 : Self.shellQuote($0) }.joined(separator: " ")
        return "\(prefix) \(command)\(scopeArguments.isEmpty ? "" : " " + scopeArguments)\(writeArgument)"
    }

    func removalCommand(for client: MCPClient) -> String? {
        client.removalCommand
    }

    func mcpJSONSample(writeEnabled: Bool) -> String? {
        var args = scope.arguments
        if writeEnabled {
            args.append("--write")
        }

        let commandPath: String
        if runtimeProfile == .development {
            commandPath = "/usr/bin/env"
            args.insert(contentsOf: ["\(DahliaApplicationSupport.profileEnvironmentKey)=development", helperPath], at: 0)
        } else {
            commandPath = helperPath
        }

        guard let command = Self.jsonString(commandPath) else { return nil }
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
