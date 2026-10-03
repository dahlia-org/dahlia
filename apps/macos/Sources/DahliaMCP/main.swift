import DahliaMeetingAccess
import DahliaRuntimeSupport
import Foundation

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

let arguments = Array(CommandLine.arguments.dropFirst())

var workspaceID: UUID?
var allowsWrites = false
var telemetryOrigin: MCPUsageTelemetryEvent.Origin?
var argumentIndex = 0
while argumentIndex < arguments.count {
    switch arguments[argumentIndex] {
    case "--workspace", "--workspace-id":
        guard workspaceID == nil, argumentIndex + 1 < arguments.count,
              let id = try? TypeID.decode(arguments[argumentIndex + 1], as: .workspace) else {
            fail("--workspace must specify one valid ws_ TypeID")
        }
        workspaceID = id
        argumentIndex += 2
    case "--write":
        guard !allowsWrites else { fail("--write may only be specified once") }
        allowsWrites = true
        argumentIndex += 1
    case "--telemetry-origin":
        guard telemetryOrigin == nil,
              argumentIndex + 1 < arguments.count,
              let origin = MCPUsageTelemetryEvent.Origin(rawValue: arguments[argumentIndex + 1]) else {
            fail("--telemetry-origin must be codexChat and may only be specified once")
        }
        telemetryOrigin = origin
        argumentIndex += 2
    default:
        fail("Usage: dahlia-mcp [--workspace <ws_TypeID>] [--write]")
    }
}

let configuredWorkspaceID = workspaceID
let configuredAllowsWrites = allowsWrites
let configuredTelemetryOrigin = telemetryOrigin
let usageTelemetryClient: MCPUsageTelemetryClient? = if configuredTelemetryOrigin != nil {
    MCPUsageTelemetryClient()
} else {
    nil
}

runMCPStandardIOWorker {
    do {
        let server: DahliaMCPServer
        if let workspaceID = configuredWorkspaceID {
            let store = try MeetingAccessStore(workspaceID: workspaceID, allowsWrites: configuredAllowsWrites)
            server = DahliaMCPServer(
                store: store,
                telemetryOrigin: configuredTelemetryOrigin,
                usageTelemetryReporter: { event in usageTelemetryClient?.record(event) }
            )
        } else {
            server = try DahliaMCPServer(allowsWrites: configuredAllowsWrites)
        }
        while let line = readLine() {
            if let response = server.handleLine(line) {
                print(response)
                fflush(stdout)
            }
        }
    } catch {
        fail("Unable to open the Dahlia database: \(error.localizedDescription)")
    }
} completion: {
    exit(EXIT_SUCCESS)
}

dispatchMain()
