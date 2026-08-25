struct SummaryGenerationOptions: Equatable {
    let exportOptions: SummaryExportOptions
    let detailLevel: SummaryDetailLevel?

    init(
        exportOptions: SummaryExportOptions,
        detailLevel: SummaryDetailLevel? = nil
    ) {
        self.exportOptions = exportOptions
        self.detailLevel = detailLevel
    }

    static let manual = Self(exportOptions: .manual)

    static func merging(_ options: [Self]) -> Self {
        Self(
            exportOptions: .merging(options.map(\.exportOptions)),
            detailLevel: options.compactMap(\.detailLevel).max { $0.mergePriority < $1.mergePriority }
        )
    }
}
