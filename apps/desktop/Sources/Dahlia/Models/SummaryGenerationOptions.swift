struct SummaryGenerationOptions: Codable, Equatable {
    let exportOptions: SummaryExportOptions
    let detailLevel: SummaryDetailLevel?
    let source: SummaryGenerationSource?

    init(
        exportOptions: SummaryExportOptions,
        detailLevel: SummaryDetailLevel? = nil,
        source: SummaryGenerationSource? = nil
    ) {
        self.exportOptions = exportOptions
        self.detailLevel = detailLevel
        self.source = source
    }

    static let manual = Self(exportOptions: .manual)

    static func merging(_ options: [Self]) -> Self {
        Self(
            exportOptions: .merging(options.map(\.exportOptions)),
            detailLevel: options.compactMap(\.detailLevel).max { $0.mergePriority < $1.mergePriority },
            source: options.compactMap(\.source).first
        )
    }
}
