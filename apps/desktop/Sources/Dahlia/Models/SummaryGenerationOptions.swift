struct SummaryGenerationOptions: Codable, Equatable {
    let exportOptions: SummaryExportOptions
    let detailLevel: SummaryDetailLevel?
    let source: SummaryGenerationSource?
    var overrides: Overrides?
    let useSavedTranscript: Bool?

    struct Overrides: Codable, Equatable {
        var outputLanguage: SummaryLanguage?
        var location: WorkspaceGenerationSettings.SummaryMode?
        var model: String?
        var reasoningEffort: String?
    }

    func applying(to settings: WorkspaceGenerationSettings) -> WorkspaceGenerationSettings {
        var settings = settings
        if let detailLevel { settings.summary.style = SummaryStyle(detailLevel: detailLevel) }
        if let language = overrides?.outputLanguage { settings.outputLanguage = language }
        if let location = overrides?.location { settings.processing.location = location }
        if settings.processing.location == .local {
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
