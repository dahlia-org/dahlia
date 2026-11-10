struct SummaryExportOptions: Codable, Equatable {
    let exportsToWorkspace: Bool

    static let manual = Self(exportsToWorkspace: true)

    static func merging(_ options: [Self]) -> Self {
        Self(exportsToWorkspace: options.contains(where: \.exportsToWorkspace))
    }
}
