import DahliaMeetingAccess
import Foundation

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2, arguments[0] == "--vault-id" else {
    fail("Usage: dahlia-mcp --vault-id <UUID> [--meeting-id <UUID> ...]")
}

guard let vaultID = UUID(uuidString: arguments[1]) else {
    fail("--vault-id must be a valid UUID")
}

var allowedMeetingIDs: Set<UUID> = []
var argumentIndex = 2
while argumentIndex < arguments.count {
    guard argumentIndex + 1 < arguments.count,
          arguments[argumentIndex] == "--meeting-id" else {
        fail("Usage: dahlia-mcp --vault-id <UUID> [--meeting-id <UUID> ...]")
    }
    guard let meetingID = UUID(uuidString: arguments[argumentIndex + 1]) else {
        fail("--meeting-id must be a valid UUID")
    }
    allowedMeetingIDs.insert(meetingID)
    argumentIndex += 2
}

do {
    let store = try MeetingAccessStore(vaultID: vaultID)
    let server = DahliaMCPServer(
        store: store,
        allowedMeetingIDs: allowedMeetingIDs.isEmpty ? nil : allowedMeetingIDs
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
