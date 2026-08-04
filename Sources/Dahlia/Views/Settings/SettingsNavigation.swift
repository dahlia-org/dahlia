enum SettingsNavigation {
    static let selectedCategoryDefaultsKey = "settingsSelectedCategory"

    static func visibleSelection(rawValue: String) -> SettingsCategory {
        switch rawValue {
        case "backups": .general
        case "liveSubtitles": .transcription
        case "audioDiagnostics": .developer
        case "instructions": .aiSummary
        default: SettingsCategory(rawValue: rawValue) ?? .general
        }
    }
}
