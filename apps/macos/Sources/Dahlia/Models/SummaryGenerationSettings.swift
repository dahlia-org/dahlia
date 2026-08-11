import Foundation

/// Immutable LLM settings captured when a summary job starts.
struct SummaryGenerationSettings: Equatable, Sendable {
    let modelID: String?
    let reasoningEffort: String
    let detailLevelInstruction: String
    let languageDisplayName: String

    @MainActor
    static func current(_ settings: AppSettings = .shared) -> Self {
        Self(
            modelID: settings.codexModelID.nilIfBlank,
            reasoningEffort: settings.codexReasoningEffort,
            detailLevelInstruction: settings.summaryDetailLevel.instruction,
            languageDisplayName: settings.llmSummaryLanguage.displayName
        )
    }
}
