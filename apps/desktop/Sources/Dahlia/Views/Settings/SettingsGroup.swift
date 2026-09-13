import Foundation

/// サイドバーで設定項目をユーザーの目的別にまとめるグループ。
enum SettingsGroup: CaseIterable, Identifiable {
    case app
    case account
    case data
    case integrations
    case advanced

    var id: Self { self }

    var label: String {
        switch self {
        case .app: L10n.thisMac
        case .account: L10n.accountPreferences
        case .data: L10n.settingsDataAndAccounts
        case .integrations: L10n.integrations
        case .advanced: L10n.advanced
        }
    }

    var categories: [SettingsCategory] {
        switch self {
        case .app: [.general, .transcription, .liveSubtitles, .screenshots, .macInference, .permissions]
        case .account: [.accountPreferences]
        case .data: [.accountsAndWorkspaces, .backups]
        case .integrations: [.calendar, .cloudStorage]
        case .advanced: [.search, .betaFeatures, .developer, .audioDiagnostics]
        }
    }
}
