import Foundation

struct ServerAccountSettings: Codable, Equatable, Sendable {
    struct AnalysisLanguages: Codable, Equatable, Sendable {
        var scope: AppLanguageScope
        var identifiers: [String]
    }

    struct SummaryModelSettings: Codable, Equatable, Sendable {
        var model = "gpt-5.4"
        var reasoningEffort = "medium"
    }

    struct Summary: Codable, Equatable, Sendable {
        struct MethodSettings: Codable, Equatable, Sendable {
            var transcript: SummaryModelSettings
            var audio: SummaryModelSettings?
        }

        var method: String
        var detail: String
        var methodSettings: MethodSettings

        var selectedSettings: SummaryModelSettings? {
            switch method {
            case "transcript", "cloudTranscription": methodSettings.transcript
            case "audio": methodSettings.audio
            default: nil
            }
        }

        var detailLevel: SummaryDetailLevel? {
            SummaryDetailLevel.fromPersistedValue(detail)
        }
    }

    var summary: Summary?
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
        struct Summary: Encodable, Sendable {
            var method: String?
            var detail: String?
            var methodSettings: MethodSettings?
        }

        struct MethodSettings: Encodable, Sendable {
            var transcript: ModelSettings?
            var audio: ModelSettings?
        }

        struct ModelSettings: Encodable, Sendable {
            var model: String?
            var reasoningEffort: String?
        }

        var summary: Summary?
    }

    struct Response: Decodable, Sendable {
        let settings: ServerAccountSettings?
    }
}
