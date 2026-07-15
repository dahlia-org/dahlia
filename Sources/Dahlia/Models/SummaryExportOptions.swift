struct SummaryExportOptions: Equatable {
    let exportsToVault: Bool
    let exportsToGoogleDocs: Bool

    static let manual = Self(
        exportsToVault: true,
        exportsToGoogleDocs: false
    )

    static func merging(_ options: [Self]) -> Self {
        Self(
            exportsToVault: options.contains(where: \.exportsToVault),
            exportsToGoogleDocs: options.contains(where: \.exportsToGoogleDocs)
        )
    }
}
