import Foundation

/// サイドバーで設定項目をユーザーの目的別にまとめるグループ。
enum SettingsGroup: CaseIterable, Identifiable {
    case app
    case account
    case workspace
    case integrations
    case advanced

    var id: Self { self }

    var label: String {
        switch self {
        case .app: L10n.thisMac
        case .account: L10n.account
        case .workspace: L10n.workspace
        case .integrations: L10n.integrations
        case .advanced: L10n.advanced
        }
    }

    var categories: [SettingsCategory] {
        switch self {
        case .app: [.general, .transcription, .liveSubtitles, .screenshots, .macInference, .permissions, .backups]
        case .account: [.accountsAndWorkspaces]
        case .workspace: [.workspace, .accountPreferences]
        case .integrations: [.calendar, .cloudStorage]
        case .advanced: [.search, .betaFeatures, .developer, .audioDiagnostics]
        }
    }
}
