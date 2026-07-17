struct SummaryGenerationOptions: Equatable {
    let previousMeetingCount: Int
    let exportOptions: SummaryExportOptions

    static let manual = Self(
        previousMeetingCount: 0,
        exportOptions: .manual
    )

    static func merging(_ options: [Self]) -> Self {
        Self(
            previousMeetingCount: options.map(\.previousMeetingCount).max() ?? 0,
            exportOptions: .merging(options.map(\.exportOptions))
        )
    }
}
