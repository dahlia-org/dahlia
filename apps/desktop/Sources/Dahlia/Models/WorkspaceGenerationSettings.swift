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
        var workflow: Workflow = .transcribeThenSummarize
        var summaryModel: String?
        var transcriptionModel: String?
        var reasoningEffort: String?
    }

    struct Processing: Codable, Equatable, Sendable {
        /// Transcription location. Summary routing follows Workspace ownership.
        var location: SummaryMode = .local
        var remote = RemoteProcessing()
    }

    struct Transcription: Codable, Equatable, Sendable {
        var localeIdentifier = "ja-JP"
        var automaticLanguageDetection = false
        var languageScope: TranscriptionLanguageScope = .all
        var languageIdentifiers: [String] = []
        var liveTranscriptDraft = false
    }

    struct Summary: Codable, Equatable, Sendable {
        var style: SummaryStyle = .detailed
        var detailLevel: SummaryDetailLevel { style.detailLevel }
    }

    struct GenerationPreferences: Codable, Equatable, Sendable {
        var processing: Processing
        var summary: Summary
        var outputLanguage: SummaryLanguage
        var transcription = Transcription()
    }

    struct LocalProcessing: Codable, Equatable, Sendable {
        var model = "gpt-5.6-luna"
        var reasoningEffort = "high"
    }

    var processing = Processing()
    var summary = Summary()
    var outputLanguage: SummaryLanguage = .ja
    var local = LocalProcessing()
    var transcription = Transcription()
    var automaticProcessing = true

    var generationPreferences: GenerationPreferences {
        .init(processing: processing, summary: summary, outputLanguage: outputLanguage, transcription: transcription)
    }
}
