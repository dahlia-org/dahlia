enum SettingsNavigation {
    static let selectedCategoryDefaultsKey = "settingsSelectedCategory"

    static func visibleSelection(_ selection: SettingsCategory) -> SettingsCategory {
        selection == .instructions ? .aiSummary : selection
    }
}
