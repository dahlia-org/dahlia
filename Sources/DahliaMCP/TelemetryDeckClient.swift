import DahliaMeetingAccess
import Foundation
@preconcurrency import TelemetryDeck

/// `lock` isolates initialization state; `record` never waits for SDK initialization or delivery.
final class MCPUsageTelemetryClient: @unchecked Sendable {
    private let lock = NSLock()
    private var isEnabled = false

    init() {
        Task.detached(priority: .utility) { [weak self] in
            guard let self, let appID = Self.telemetryAppID() else { return }
            let configuration = TelemetryDeck.Config(appID: appID)
            #if DEBUG
                configuration.testMode = true
            #endif
            configuration.defaultParameters = { ["runtime": "mcpHelper"] }
            TelemetryDeck.initialize(config: configuration)
            lock.withLock {
                isEnabled = true
            }
        }
    }

    func record(_ event: MCPUsageTelemetryEvent) {
        guard lock.withLock({ isEnabled }) else { return }
        TelemetryDeck.signal(event.signalName, parameters: event.parameters)
    }

    private static func telemetryAppID() -> String? {
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let contentsURL = executableURL.deletingLastPathComponent().deletingLastPathComponent()
        guard contentsURL.lastPathComponent == "Contents",
              let data = try? Data(contentsOf: contentsURL.appending(path: "Info.plist")),
              let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let rawValue = dictionary["TELEMETRYDECK_APP_ID"] as? String else { return nil }
        let appID = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return appID.isEmpty ? nil : appID
    }
}
