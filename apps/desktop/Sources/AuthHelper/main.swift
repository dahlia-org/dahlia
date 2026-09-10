import DahliaRuntimeSupport
import Foundation

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(EXIT_FAILURE)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 7, args[0] == "token", args[1] == "--provider",
      let provider = DahliaTokenBrokerProtocol.Provider(rawValue: args[2]),
      args[3] == "--connection-id", let id = UUID(uuidString: args[4]),
      args[5] == "--profile", let profile = DahliaRuntimeProfile(rawValue: args[6]) else {
    fail("Usage: auth-helper token --provider <databricks|dahlia> --connection-id <UUID> --profile <production|development>")
}

do {
    try print(DahliaTokenBrokerProtocol.requestToken(connectionID: id, provider: provider, profile: profile))
} catch {
    fail("Authentication failed. Check the sign-in status in Dahlia.")
}
