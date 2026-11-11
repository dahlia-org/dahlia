import Foundation

/// サイドバーで設定項目をユーザーの目的別にまとめるグループ。
enum SettingsGroup: CaseIterable, Identifiable {
    case app
    case account
    case advanced

    var id: Self { self }

    var label: String {
        switch self {
        case .app: L10n.thisMac
        case .account: L10n.account
        case .advanced: L10n.advanced
        }
    }

    var categories: [SettingsCategory] {
        switch self {
        case .app: [.general, .appearance, .transcription, .liveSubtitles, .screenshots, .meetingLinks, .permissions, .backups]
        case .account: [.workspace, .agents, .calendar]
        case .advanced: [.search, .betaFeatures, .audioDiagnostics]
        }
    }
}
