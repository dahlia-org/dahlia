import DahliaRuntimeSupport
import Foundation

public struct MCPCommandLineOptions {
    public private(set) var workspaceID: UUID?
    public private(set) var accountScope: MCPAccountScope?
    public private(set) var allowsWrites = false
    public private(set) var telemetryOrigin: MCPUsageTelemetryEvent.Origin?

    public init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--workspace", "--workspace-id":
                guard workspaceID == nil, index + 1 < arguments.count,
                      let id = try? TypeID.decode(arguments[index + 1], as: .workspace) else {
                    throw Failure.message("--workspace must specify one valid ws_ TypeID")
                }
                workspaceID = id
                index += 2
            case "--account":
                guard accountScope == nil, index + 1 < arguments.count else {
                    throw Failure.message("--account must specify one account and may only be specified once")
                }
                accountScope = try MCPAccountScope(argument: arguments[index + 1])
                index += 2
            case "--write":
                guard !allowsWrites else { throw Failure.message("--write may only be specified once") }
                allowsWrites = true
                index += 1
            case "--telemetry-origin":
                guard telemetryOrigin == nil, index + 1 < arguments.count,
                      let origin = MCPUsageTelemetryEvent.Origin(rawValue: arguments[index + 1]) else {
                    throw Failure.message("--telemetry-origin must be codexChat and may only be specified once")
                }
                telemetryOrigin = origin
                index += 2
            default:
                throw Failure.message("Usage: dahlia-mcp [--account <UUID|local> | --workspace <ws_TypeID>] [--write]")
            }
        }
        guard accountScope == nil || workspaceID == nil else { throw MCPAccountScope.Failure.conflictingScopes }
    }

    private enum Failure: Error, LocalizedError {
        case message(String)

        var errorDescription: String? {
            switch self {
            case let .message(message): message
            }
        }
    }
}
