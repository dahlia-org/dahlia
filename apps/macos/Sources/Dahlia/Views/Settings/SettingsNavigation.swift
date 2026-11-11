import Foundation

enum SettingsNavigation {
    static let selectedCategoryDefaultsKey = "settingsSelectedCategory"

    static func savedSelection(in defaults: UserDefaults = .standard) -> SettingsCategory {
        defaults.string(forKey: selectedCategoryDefaultsKey)
            .flatMap(SettingsCategory.init(rawValue:))
            .map(visibleSelection) ?? .general
    }

    static func saveSelection(_ selection: SettingsCategory, in defaults: UserDefaults = .standard) {
        defaults.set(visibleSelection(selection).rawValue, forKey: selectedCategoryDefaultsKey)
    }

    static func visibleSelection(_ selection: SettingsCategory) -> SettingsCategory {
        switch selection {
        case .language:
            .general
        case .accountsAndWorkspaces, .dahliaAccounts, .accountPreferences, .macInference, .modelProvider, .aiSummary, .instructions, .mcp:
            .agents
        case .workspacePreferences:
            .workspace
        case .eventDisplay:
            .appearance
        case .transcription, .recordingStopDetection, .liveSubtitles, .screenshots, .meetingLinks:
            .meetings
        default:
            selection
        }
    }
}
