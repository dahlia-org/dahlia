struct SummaryGenerationOptions: Equatable {
    let exportOptions: SummaryExportOptions

    static let manual = Self(exportOptions: .manual)

    static func merging(_ options: [Self]) -> Self {
        Self(exportOptions: .merging(options.map(\.exportOptions)))
    }
}
