@preconcurrency import TelemetryDeck

@MainActor
protocol UsageTelemetryClient: AnyObject {
    func start(appID: String, testMode: Bool) async
    func signal(_ name: String, parameters: [String: String], floatValue: Double?)
}

@MainActor
final class TelemetryDeckClient: UsageTelemetryClient {
    func start(appID: String, testMode: Bool) async {
        await Task.detached(priority: .utility) {
            let configuration = TelemetryDeck.Config(appID: appID)
            configuration.testMode = testMode
            configuration.defaultParameters = { ["runtime": "app"] }
            TelemetryDeck.initialize(config: configuration)
        }.value
    }

    func signal(_ name: String, parameters: [String: String], floatValue: Double?) {
        TelemetryDeck.signal(name, parameters: parameters, floatValue: floatValue)
    }
}
