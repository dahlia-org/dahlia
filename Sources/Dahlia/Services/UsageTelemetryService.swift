import Foundation

/// Sends allowlisted, content-free product metrics through TelemetryDeck's asynchronous queue.
@MainActor
final class UsageTelemetryService {
    static let shared = UsageTelemetryService(client: TelemetryDeckClient())

    private static let appIDInfoKey = "TELEMETRYDECK_APP_ID"

    private let client: any UsageTelemetryClient
    private var startupTask: Task<Void, Never>?
    private(set) var isEnabled = false

    init(client: any UsageTelemetryClient) {
        self.client = client
    }

    func start(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:],
        testMode: Bool = UsageTelemetryService.isDebugBuild
    ) {
        guard !isEnabled,
              startupTask == nil,
              let appID = Self.resolveAppID(infoDictionary: infoDictionary)
        else { return }
        startupTask = Task { [weak self, client] in
            await client.start(appID: appID, testMode: testMode)
            guard let self else { return }
            self.isEnabled = true
            self.startupTask = nil
        }
    }

    func record(_ event: UsageTelemetryEvent) {
        guard isEnabled else { return }
        client.signal(event.signalName, parameters: event.parameters)
    }

    static func resolveAppID(infoDictionary: [String: Any]) -> String? {
        guard let rawValue = infoDictionary[appIDInfoKey] as? String else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static var isDebugBuild: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }
}
