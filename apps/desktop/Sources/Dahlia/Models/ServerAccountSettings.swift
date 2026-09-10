import Foundation

struct ServerAccountSettings: Codable, Equatable, Sendable {
    struct AnalysisLanguages: Codable, Equatable, Sendable {
        var scope: AppLanguageScope
        var identifiers: [String]
    }

    enum SummaryMode: String, Codable, CaseIterable, Identifiable, Sendable {
        case local, remote
        var id: Self { self }
    }

    enum Workflow: String, Codable, CaseIterable, Identifiable, Sendable {
        case transcribeThenSummarize, combined
        var id: Self { self }
    }

    struct RemoteProcessing: Codable, Equatable, Sendable {
        var workflow: Workflow = .transcribeThenSummarize
        var summaryModel: String?
        var transcriptionModel: String?
        var reasoningEffort: String?
    }

    struct Processing: Codable, Equatable, Sendable {
        var location: SummaryMode = .local
        var remote = RemoteProcessing()
    }

    struct Summary: Codable, Equatable, Sendable {
        var style: SummaryStyle = .detailed
        var detailLevel: SummaryDetailLevel { style.detailLevel }
    }

    struct GenerationPreferences: Codable, Equatable, Sendable {
        var processing: Processing
        var summary: Summary
        var outputLanguage: SummaryLanguage
    }

    var processing: Processing?
    var summary: Summary?
    var outputLanguage: SummaryLanguage
    var analysisLanguages: AnalysisLanguages
    private(set) var legacyMethod: String?

    var generationPreferences: GenerationPreferences {
        .init(processing: processing ?? .init(), summary: summary ?? .init(), outputLanguage: outputLanguage)
    }

    init(processing: Processing? = nil, summary: Summary? = nil, outputLanguage: SummaryLanguage, analysisLanguages: AnalysisLanguages) {
        self.processing = processing
        self.summary = summary
        self.outputLanguage = outputLanguage
        self.analysisLanguages = analysisLanguages
    }

    private enum CodingKeys: String, CodingKey { case processing, summary, outputLanguage, analysisLanguages, legacyMethod }

    /// Only persisted recording snapshots need the previous account-settings representations.
    private struct LegacySummary: Decodable {
        struct Model: Decodable { var model: String
            var reasoningEffort: String
        }

        struct Methods: Decodable { var transcript: Model?
            var audio: Model?
        }

        struct Remote: Decodable {
            var detail: String
            var model: String
            var reasoningEffort: String
            var transcriptionModel: String?
        }

        var mode: SummaryMode?
        var remote: Remote?
        var method: String?
        var detail: String?
        var methodSettings: Methods?
        var legacyMethod: String?
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        outputLanguage = try values.decode(SummaryLanguage.self, forKey: .outputLanguage)
        analysisLanguages = try values.decode(AnalysisLanguages.self, forKey: .analysisLanguages)
        legacyMethod = try values.decodeIfPresent(String.self, forKey: .legacyMethod)
        if values.contains(.processing) {
            processing = try values.decodeIfPresent(Processing.self, forKey: .processing)
            summary = try values.decodeIfPresent(Summary.self, forKey: .summary)
        } else if let legacy = try values.decodeIfPresent(LegacySummary.self, forKey: .summary) {
            let method = legacy.method
            let selected = method == "audio" ? legacy.methodSettings?.audio : legacy.methodSettings?.transcript
            let transcriptionModel = legacy.remote?.transcriptionModel
                ?? (method == "cloudTranscription" ? legacy.methodSettings?.audio?.model ?? "gemini-3-8-flash" : nil)
            processing = .init(location: legacy.mode ?? (method == "transcript" ? .local : .remote), remote: .init(
                workflow: transcriptionModel == nil ? .combined : .transcribeThenSummarize,
                summaryModel: legacy.remote?.model ?? selected?.model ?? "gemini-3-8-flash",
                transcriptionModel: transcriptionModel,
                reasoningEffort: legacy.remote?.reasoningEffort ?? selected?.reasoningEffort ?? "medium"
            ))
            summary = .init(style: SummaryStyle(detailLevel: .fromPersistedValue(legacy.remote?.detail ?? legacy.detail ?? "high")))
            legacyMethod = legacy.legacyMethod ?? method
        }
    }

    @MainActor
    static func initialValues(from settings: AppSettings = .shared) -> Self {
        Self(
            processing: .init(), summary: .init(style: SummaryStyle(detailLevel: settings.summaryDetailLevel)),
            outputLanguage: settings.llmSummaryLanguage,
            analysisLanguages: AnalysisLanguages(scope: settings.appLanguageScope, identifiers: settings.enabledLanguageIdentifiers.sorted())
        )
    }

    struct Patch: Encodable, Sendable {
        var outputLanguage: SummaryLanguage?
        var analysisLanguages: AnalysisLanguages?
        var initialize: Bool?
        struct Summary: Encodable, Sendable { var style: SummaryStyle? }
        struct Processing: Encodable, Sendable {
            var location: SummaryMode?
            var remote: Remote?
        }

        struct Remote: Encodable, Sendable {
            var workflow: Workflow?
            var summaryModel: String??
            var transcriptionModel: String??
            var reasoningEffort: String??
        }

        var summary: Summary?
        var processing: Processing?
    }

    struct Response: Decodable, Sendable {
        let settings: ServerAccountSettings?
    }
}
