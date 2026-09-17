import Foundation

/// Shared generation defaults, stored with the Workspace and captured by each job.
struct WorkspaceGenerationSettings: Codable, Equatable, Sendable {
    enum SummaryMode: String, Codable, CaseIterable, Identifiable, Sendable {
        case local, remote
        var id: Self { self }
    }

    enum Workflow: String, Codable, CaseIterable, Identifiable, Sendable {
        case transcribeThenSummarize, combined
        var id: Self { self }
    }

    struct RemoteProcessing: Codable, Equatable, Sendable {
        var workflow: Workflow = .combined
        var summaryModel: String?
        var reasoningEffort: String?
    }

    struct Processing: Codable, Equatable, Sendable {
        /// Transcription location. Summary routing follows Workspace ownership.
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

    struct LocalProcessing: Codable, Equatable, Sendable {
        var model = "gpt-5.6-luna"
        var reasoningEffort = "high"
    }

    struct LegacyTranscription: Codable, Equatable, Sendable {
        var localeIdentifier: String
        var automaticLanguageDetection: Bool
        var languageScope: TranscriptionLanguageScope
        var languageIdentifiers: [String]
        var liveTranscriptDraft: Bool
    }

    var processing = Processing()
    var summary = Summary()
    var outputLanguage: SummaryLanguage = .ja
    var local = LocalProcessing()
    var automaticProcessing = true
    private(set) var legacyTranscription: LegacyTranscription?

    init(
        processing: Processing = Processing(),
        summary: Summary = Summary(),
        outputLanguage: SummaryLanguage = .ja,
        local: LocalProcessing = LocalProcessing(),
        automaticProcessing: Bool = true
    ) {
        self.processing = processing
        self.summary = summary
        self.outputLanguage = outputLanguage
        self.local = local
        self.automaticProcessing = automaticProcessing
    }

    private enum CodingKeys: String, CodingKey {
        case processing, summary, outputLanguage, local, automaticProcessing, transcription
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        processing = try values.decodeIfPresent(Processing.self, forKey: .processing) ?? Processing()
        summary = try values.decodeIfPresent(Summary.self, forKey: .summary) ?? Summary()
        outputLanguage = try values.decodeIfPresent(SummaryLanguage.self, forKey: .outputLanguage) ?? .ja
        local = try values.decodeIfPresent(LocalProcessing.self, forKey: .local) ?? LocalProcessing()
        automaticProcessing = try values.decodeIfPresent(Bool.self, forKey: .automaticProcessing) ?? true
        legacyTranscription = try values.decodeIfPresent(LegacyTranscription.self, forKey: .transcription)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(processing, forKey: .processing)
        try values.encode(summary, forKey: .summary)
        try values.encode(outputLanguage, forKey: .outputLanguage)
        try values.encode(local, forKey: .local)
        try values.encode(automaticProcessing, forKey: .automaticProcessing)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.processing == rhs.processing && lhs.summary == rhs.summary && lhs.outputLanguage == rhs.outputLanguage
            && lhs.local == rhs.local && lhs.automaticProcessing == rhs.automaticProcessing
    }

    var generationPreferences: GenerationPreferences {
        .init(processing: processing, summary: summary, outputLanguage: outputLanguage)
    }
}
