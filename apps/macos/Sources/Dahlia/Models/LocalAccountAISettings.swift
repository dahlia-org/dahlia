import Foundation

/// Local account provider credentials. Historical keys remain compatible with released clients.
struct LocalAccountAISettings: Equatable, Sendable {
    static let providerKey = "codexAccountProvider"
    static let databricksProfileKey = "llmDatabricksProfile"
    static let migrationKey = "localAccountAISettingsMigrated"
    static let summaryMigrationKey = "localAccountSummarySettingsMigrated"
    static let summaryModelKey = "codexModelID"
    static let summaryReasoningEffortKey = "codexReasoningEffort"

    var provider: AIAccountProvider
    var databricksProfile: String

    var runtimeProvider: CodexRuntimeProvider {
        .local
    }

    init(provider: AIAccountProvider, databricksProfile: String) {
        self.provider = provider
        self.databricksProfile = databricksProfile
    }

    init(defaults: UserDefaults) {
        provider = defaults.string(forKey: Self.providerKey)
            .flatMap(AIAccountProvider.init(rawValue:)) ?? .chatGPTSubscription
        databricksProfile = defaults.string(forKey: Self.databricksProfileKey) ?? ""
    }

    func save(to defaults: UserDefaults) {
        defaults.set(provider.rawValue, forKey: Self.providerKey)
        defaults.set(databricksProfile, forKey: Self.databricksProfileKey)
        defaults.set(true, forKey: Self.migrationKey)
    }
}

/// Device-local preferences shared by the Workspaces belonging to one account.
struct AccountInferenceSettings: Codable, Equatable, Sendable {
    var summary = WorkspaceGenerationSettings.Summary()
    var local = WorkspaceGenerationSettings.LocalProcessing()
    private var savedImageAnalysis: WorkspaceGenerationSettings.ImageAnalysis?
    var imageAnalysis: WorkspaceGenerationSettings.ImageAnalysis {
        get {
            var settings = savedImageAnalysis ?? .init()
            if settings.model == nil, settings.reasoningEffort == nil {
                settings.model = savedScreenshotSelection?.model
                settings.reasoningEffort = savedScreenshotSelection?.reasoningEffort
            }
            return settings
        }
        set {
            savedImageAnalysis = newValue
            savedScreenshotSelection = nil
        }
    }

    private var savedScreenshotSelection: WorkspaceGenerationSettings.ScreenshotSelection?

    var automaticProcessing = true
    var liveTranscriptDraft = false
    var chatModelID = ""
    var chatReasoningEffort = CodexReasoningEffortOption.defaultValue

    /// One key per account: a Dahlia account, a Databricks account (`databricks.<id>`), or the Local Account.
    static func key(connectionID: UUID?, databricksConnectionID: UUID? = nil) -> String {
        "accountInferenceSettings." + (connectionID?.uuidString.lowercased()
            ?? databricksConnectionID.map { "databricks." + $0.uuidString.lowercased() } ?? "local")
    }

    init(workspace: WorkspaceRecord, defaults: UserDefaults = .standard) {
        let key = Self.key(connectionID: workspace.accountConnectionId, databricksConnectionID: workspace.databricksConnectionId)
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(Self.self, from: data) {
            self = saved
            return
        }
        imageAnalysis = workspace.generationSettings.imageAnalysis
        summary = workspace.generationSettings.summary
        local = workspace.generationSettings.local
        automaticProcessing = workspace.generationSettings.automaticProcessing
        liveTranscriptDraft = workspace.generationSettings.liveTranscriptDraft
        chatModelID = workspace.chatModelID
        chatReasoningEffort = workspace.chatReasoningEffort
        if workspace.accountConnectionId == nil, workspace.databricksConnectionId != nil {
            // A Databricks account starts with only its gateway's default model on, so its summaries use it. Image
            // analysis keeps no saved model and prefers the same one (`CodexScreenshotAnalysisService.defaultModel`).
            if local.model == WorkspaceGenerationSettings.LocalProcessing().model { local.model = PiProviderConfiguration.databricksDefaultModel }
        }
        // Releases before per-account settings kept the Local Account's summary model in app defaults.
        if workspace.accountConnectionId == nil, workspace.databricksConnectionId == nil {
            local.model = defaults.string(forKey: LocalAccountAISettings.summaryModelKey) ?? local.model
            local.reasoningEffort = defaults.string(forKey: LocalAccountAISettings.summaryReasoningEffortKey) ?? local.reasoningEffort
        }
    }

    init(snapshot: WorkspaceAISettingsSnapshot) {
        imageAnalysis = snapshot.generationSettings.imageAnalysis
        summary = snapshot.generationSettings.summary
        local = snapshot.generationSettings.local
        automaticProcessing = snapshot.generationSettings.automaticProcessing
        liveTranscriptDraft = snapshot.generationSettings.liveTranscriptDraft
        chatModelID = snapshot.chatModelID
        chatReasoningEffort = snapshot.chatReasoningEffort
    }

    func save(connectionID: UUID?, databricksConnectionID: UUID? = nil, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key(connectionID: connectionID, databricksConnectionID: databricksConnectionID))
    }

    func generationSettings(outputLanguage: SummaryLanguage) -> WorkspaceGenerationSettings {
        .init(
            summary: summary,
            outputLanguage: outputLanguage,
            local: local,
            imageAnalysis: imageAnalysis,
            automaticProcessing: automaticProcessing,
            liveTranscriptDraft: liveTranscriptDraft
        )
    }
}
