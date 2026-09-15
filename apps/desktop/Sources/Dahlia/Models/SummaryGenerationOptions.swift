struct SummaryGenerationOptions: Codable, Equatable {
    let exportOptions: SummaryExportOptions
    let detailLevel: SummaryDetailLevel?
    let source: SummaryGenerationSource?
    var overrides: Overrides?
    let useSavedTranscript: Bool?

    struct Overrides: Codable, Equatable {
        var outputLanguage: SummaryLanguage?
        var model: String?
        var reasoningEffort: String?

        func isModelAvailable(defaultModel: String, modelIDs: [String], allowsAutomatic: Bool) -> Bool {
            let effectiveModel = model ?? defaultModel
            return effectiveModel.isEmpty ? allowsAutomatic : modelIDs.contains(effectiveModel)
        }

        mutating func selectModel(_ model: String?, defaultReasoningEffort: String?) {
            guard self.model != model else { return }
            self.model = model
            reasoningEffort = model == nil ? nil : defaultReasoningEffort
        }
    }

    func applying(to settings: WorkspaceGenerationSettings, usesServer: Bool) -> WorkspaceGenerationSettings {
        var settings = settings
        if let detailLevel { settings.summary.style = SummaryStyle(detailLevel: detailLevel) }
        if let language = overrides?.outputLanguage { settings.outputLanguage = language }
        if !usesServer {
            if let model = overrides?.model { settings.local.model = model }
            if let effort = overrides?.reasoningEffort { settings.local.reasoningEffort = effort }
        } else {
            if let model = overrides?.model { settings.processing.remote.summaryModel = model.nilIfBlank }
            if let effort = overrides?.reasoningEffort { settings.processing.remote.reasoningEffort = effort.nilIfBlank }
        }
        return settings
    }

    init(
        exportOptions: SummaryExportOptions,
        detailLevel: SummaryDetailLevel? = nil,
        source: SummaryGenerationSource? = nil,
        overrides: Overrides? = nil,
        useSavedTranscript: Bool? = nil
    ) {
        self.exportOptions = exportOptions
        self.detailLevel = detailLevel
        self.source = source
        self.overrides = overrides
        self.useSavedTranscript = useSavedTranscript
    }

    static let manual = Self(exportOptions: .manual)

    static func merging(_ options: [Self]) -> Self {
        Self(
            exportOptions: .merging(options.map(\.exportOptions)),
            detailLevel: options.compactMap(\.detailLevel).max { $0.mergePriority < $1.mergePriority },
            source: options.compactMap(\.source).first,
            overrides: options.compactMap(\.overrides).first,
            useSavedTranscript: !options.isEmpty && options.allSatisfy { $0.useSavedTranscript == true } ? true : nil
        )
    }
}
