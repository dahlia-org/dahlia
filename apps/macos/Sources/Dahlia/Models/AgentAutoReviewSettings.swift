import Foundation

/// An empty selection follows the model of each chat; explicit reviewer models belong to the execution account.
enum AgentAutoReviewSettings {
    static let triageModelID = "system.ai.openjev-qwen35-4b"
    /// Bundled in `PiExtension/pi-auto-review`. Dahlia imports only its `review()`; Pi loads no package extension.
    static func entryURL() throws -> URL {
        try PiBundle.resourceURL("pi-auto-review/index.ts")
    }

    /// Earlier releases installed the plugin from the Plugins tab; the Plugins tab hides that leftover declaration.
    static func isPackage(_ source: String) -> Bool {
        source.contains("github.com/mats16/pi-auto-review") || source.contains("github.com:mats16/pi-auto-review")
    }

    static func triageDefaultsKey() -> String {
        "autoReviewTriage.\(AppAccount.key)"
    }

    static func triageEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: triageDefaultsKey())
    }

    static func triageConfiguration(services: [JSONValue], gateway: AgentMCPProvider) -> JSONValue? {
        guard services.contains(where: {
            $0.objectValue?["name"]?.stringValue?.split(separator: "/").last == Substring(triageModelID)
                && $0.objectValue?["supported_api_types"]?.arrayValue?.contains(.string("typesafe/v1/systemone")) == true
        }) else { return nil }
        return .object([
            "model": .string(triageModelID),
            "provider": .string(gateway.id),
            "endpoint": .string(gateway.workspaceURL.appending(path: "ai-gateway/typesafe/v1/systemone").absoluteString),
        ])
    }

    static func defaultsKey() -> String {
        "autoReviewModel.\(AppAccount.key)"
    }

    static func model(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: defaultsKey()) ?? ""
    }
}
