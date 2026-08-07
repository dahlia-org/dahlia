enum SettingsNavigation {
    static let selectedCategoryDefaultsKey = "settingsSelectedCategory"

    static func visibleSelection(_ selection: SettingsCategory) -> SettingsCategory {
        switch selection {
        case .instructions, .mcp:
            .aiSummary
        default:
            selection
        }
    }
}
