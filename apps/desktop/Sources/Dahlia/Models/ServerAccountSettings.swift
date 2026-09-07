import Foundation

struct ServerAccountSettings: Codable, Equatable, Sendable {
    struct AnalysisLanguages: Codable, Equatable, Sendable {
        var scope: AppLanguageScope
        var identifiers: [String]
    }

    var outputLanguage: SummaryLanguage
    var analysisLanguages: AnalysisLanguages

    @MainActor
    static func initialValues(from settings: AppSettings = .shared) -> Self {
        Self(
            outputLanguage: settings.llmSummaryLanguage,
            analysisLanguages: AnalysisLanguages(
                scope: settings.appLanguageScope,
                identifiers: settings.enabledLanguageIdentifiers.sorted()
            )
        )
    }

    struct Patch: Encodable, Sendable {
        var outputLanguage: SummaryLanguage?
        var analysisLanguages: AnalysisLanguages?
        var initialize: Bool?
    }

    struct Response: Decodable, Sendable {
        let settings: ServerAccountSettings?
    }
}
