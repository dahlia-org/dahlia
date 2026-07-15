import DahliaMeetingAccess
import Foundation

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2, arguments[0] == "--vault-id" else {
    fail("Usage: dahlia-mcp --vault-id <UUID>")
}

guard let vaultID = UUID(uuidString: arguments[1]) else {
    fail("--vault-id must be a valid UUID")
}

do {
    let store = try MeetingAccessStore(vaultID: vaultID)
    let server = DahliaMCPServer(store: store)
    while let line = readLine() {
        if let response = server.handleLine(line) {
            print(response)
            fflush(stdout)
        }
    }
} catch {
    fail("Unable to open the Dahlia database: \(error.localizedDescription)")
}
