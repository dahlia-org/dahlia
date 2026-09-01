import DahliaMeetingAccess
import DahliaRuntimeSupport
import Foundation

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "auth" {
    guard arguments.count == 6,
          arguments[1] == "token",
          arguments[2] == "--connection-id",
          let connectionID = UUID(uuidString: arguments[3]),
          arguments[4] == "--profile",
          let profile = DahliaRuntimeProfile(rawValue: arguments[5])
    else {
        fail("Usage: dahlia-mcp auth token --connection-id <UUID> --profile <production|development>")
    }
    do {
        try print(DahliaTokenBrokerProtocol.requestToken(connectionID: connectionID, profile: profile))
        exit(EXIT_SUCCESS)
    } catch {
        fail(error.localizedDescription)
    }
}

guard arguments.count >= 2, arguments[0] == "--vault-id" else {
    fail("Usage: dahlia-mcp --vault-id <UUID> [--write]")
}

guard let vaultID = UUID(uuidString: arguments[1]) else {
    fail("--vault-id must be a valid UUID")
}

var allowsWrites = false
var telemetryOrigin: MCPUsageTelemetryEvent.Origin?
var argumentIndex = 2
while argumentIndex < arguments.count {
    switch arguments[argumentIndex] {
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
        fail("Usage: dahlia-mcp --vault-id <UUID> [--write]")
    }
}

let configuredAllowsWrites = allowsWrites
let configuredTelemetryOrigin = telemetryOrigin
let usageTelemetryClient: MCPUsageTelemetryClient? = if configuredTelemetryOrigin != nil {
    MCPUsageTelemetryClient()
} else {
    nil
}

runMCPStandardIOWorker {
    do {
        let store = try MeetingAccessStore(vaultID: vaultID, allowsWrites: configuredAllowsWrites)
        let server = DahliaMCPServer(
            store: store,
            telemetryOrigin: configuredTelemetryOrigin,
            usageTelemetryReporter: { event in usageTelemetryClient?.record(event) }
        )
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
