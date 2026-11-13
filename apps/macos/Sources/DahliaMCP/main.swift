import DahliaMeetingAccess
import DahliaRuntimeSupport
import Foundation

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

let options: MCPCommandLineOptions
do {
    options = try MCPCommandLineOptions(arguments: Array(CommandLine.arguments.dropFirst()))
} catch {
    fail(error.localizedDescription)
}

let configuredAccountScope = options.accountScope
let configuredWorkspaceID = options.workspaceID
let configuredAllowsWrites = options.allowsWrites
let configuredTelemetryOrigin = options.telemetryOrigin
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
            server = try DahliaMCPServer(accountScope: configuredAccountScope, allowsWrites: configuredAllowsWrites)
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
