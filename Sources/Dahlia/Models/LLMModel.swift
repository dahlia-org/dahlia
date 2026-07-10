/// ユーザーが選択できる LLM。プロバイダー固有のモデル ID は送信時に解決する。
enum LLMModel: String, CaseIterable, Identifiable {
    case gpt56Sol = "gpt-5-6-sol"
    case gpt56Terra = "gpt-5-6-terra"
    case gpt56Luna = "gpt-5-6-luna"
    case gpt55 = "gpt-5-5"

    static let defaultModel = LLMModel.gpt56Sol

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gpt56Sol: L10n.gpt56Sol
        case .gpt56Terra: L10n.gpt56Terra
        case .gpt56Luna: L10n.gpt56Luna
        case .gpt55: L10n.gpt55
        }
    }

    func identifier(for provider: LLMProvider) -> String {
        switch provider {
        case .openAI:
            rawValue
        case .databricks:
            "system.ai.\(rawValue)"
        }
    }

    static func fromPersistedValue(_ value: String) -> LLMModel? {
        if let model = LLMModel(rawValue: value) {
            return model
        }

        let databricksPrefix = "system.ai."
        guard value.hasPrefix(databricksPrefix) else { return nil }
        return LLMModel(rawValue: String(value.dropFirst(databricksPrefix.count)))
    }
}
