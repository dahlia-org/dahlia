@preconcurrency import TelemetryDeck

@MainActor
protocol UsageTelemetryClient: AnyObject {
    func start(appID: String, testMode: Bool) async
    func signal(_ name: String, parameters: [String: String])
}

@MainActor
final class TelemetryDeckClient: UsageTelemetryClient {
    func start(appID: String, testMode: Bool) async {
        await Task.detached(priority: .utility) {
            let configuration = TelemetryDeck.Config(appID: appID)
            configuration.testMode = testMode
            TelemetryDeck.initialize(config: configuration)
        }.value
    }

    func signal(_ name: String, parameters: [String: String]) {
        TelemetryDeck.signal(name, parameters: parameters)
    }
}
