import DahliaMeetingAccess
import Foundation

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2, arguments[0] == "--vault-id" else {
    fail("Usage: dahlia-mcp --vault-id <UUID> [--write | --meeting-id <UUID> ...]")
}

guard let vaultID = UUID(uuidString: arguments[1]) else {
    fail("--vault-id must be a valid UUID")
}

var allowedMeetingIDs: Set<UUID> = []
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
            fail("--telemetry-origin must be codexChat or summary and may only be specified once")
        }
        telemetryOrigin = origin
        argumentIndex += 2
    case "--meeting-id":
        guard argumentIndex + 1 < arguments.count else {
            fail("Usage: dahlia-mcp --vault-id <UUID> [--write | --meeting-id <UUID> ...]")
        }
        guard let meetingID = UUID(uuidString: arguments[argumentIndex + 1]) else {
            fail("--meeting-id must be a valid UUID")
        }
        allowedMeetingIDs.insert(meetingID)
        argumentIndex += 2
    default:
        fail("Usage: dahlia-mcp --vault-id <UUID> [--write | --meeting-id <UUID> ...]")
    }
}

guard !allowsWrites || allowedMeetingIDs.isEmpty else {
    fail("--write cannot be combined with --meeting-id")
}

let configuredAllowedMeetingIDs = allowedMeetingIDs
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
            allowedMeetingIDs: configuredAllowedMeetingIDs.isEmpty ? nil : configuredAllowedMeetingIDs,
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
