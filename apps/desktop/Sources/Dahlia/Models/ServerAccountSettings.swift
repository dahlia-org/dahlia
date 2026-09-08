import Foundation

struct ServerAccountSettings: Codable, Equatable, Sendable {
    struct AnalysisLanguages: Codable, Equatable, Sendable {
        var scope: AppLanguageScope
        var identifiers: [String]
    }

    struct TranscriptSummary: Codable, Equatable, Sendable {
        var model = "gpt-5.4"
        var reasoningEffort = "medium"
        var detail = "detailed"
    }

    struct Summary: Codable, Equatable, Sendable {
        struct MethodSettings: Codable, Equatable, Sendable {
            var transcript: TranscriptSummary
            var audio: TranscriptSummary?
        }

        var method: String
        var methodSettings: MethodSettings

        var selectedSettings: TranscriptSummary? {
            switch method {
            case "transcript": methodSettings.transcript
            case "audio": methodSettings.audio
            default: nil
            }
        }

        var detailLevel: SummaryDetailLevel? {
            selectedSettings.flatMap { SummaryDetailLevel(rawValue: $0.detail) }
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
            var methodSettings: MethodSettings?
        }

        struct MethodSettings: Encodable, Sendable {
            var transcript: Transcript?
            var audio: Transcript?
        }

        struct Transcript: Encodable, Sendable {
            var model: String?
            var reasoningEffort: String?
            var detail: String?
        }

        var summary: Summary?
    }

    struct Response: Decodable, Sendable {
        let settings: ServerAccountSettings?
    }
}
