struct SummaryExportOptions: Codable, Equatable {
    let exportsToWorkspace: Bool
    let exportsToGoogleDocs: Bool

    static let manual = Self(
        exportsToWorkspace: true,
        exportsToGoogleDocs: false
    )

    static func merging(_ options: [Self]) -> Self {
        Self(
            exportsToWorkspace: options.contains(where: \.exportsToWorkspace),
            exportsToGoogleDocs: options.contains(where: \.exportsToGoogleDocs)
        )
    }
}
