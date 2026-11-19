import Foundation

/// An empty selection follows the model of each chat; explicit reviewer models belong to the execution account.
enum AgentAutoReviewSettings {
    static let triageModelID = "system.ai.openjev-qwen35-4b"
    /// Installed from the Plugins tab. Pinned to a reviewed commit that has the per-call settings of `review()`.
    static let packageSource = "https://github.com/mats16/pi-auto-review@3a12a7db97760e0a22ae9b4c0fa52f1497b6b046"

    /// A source Pi installs at `entryURL`, whatever its ref or form.
    static func isPackage(_ source: String) -> Bool {
        source.contains("github.com/mats16/pi-auto-review") || source.contains("github.com:mats16/pi-auto-review")
    }

    /// Where Pi clones `packageSource`, whatever its ref. Dahlia imports only its `review()`; Pi loads no package extension.
    static func entryURL(agentURL: URL) -> URL {
        agentURL.appending(path: "git/github.com/mats16/pi-auto-review/index.ts")
    }

    static func triageDefaultsKey(for account: CodexRuntimeProvider) -> String {
        "autoReviewTriage.\(account.accountKey)"
    }

    static func triageEnabled(for account: CodexRuntimeProvider, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: triageDefaultsKey(for: account))
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

    static func defaultsKey(for account: CodexRuntimeProvider) -> String {
        "autoReviewModel.\(account.accountKey)"
    }

    static func model(for account: CodexRuntimeProvider, defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: defaultsKey(for: account)) ?? ""
    }
}
