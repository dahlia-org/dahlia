import Foundation

/// サイドバーで設定項目をユーザーの目的別にまとめるグループ。
enum SettingsGroup: CaseIterable, Identifiable {
    case app
    case meetings
    case integrations
    case ai
    case advanced

    var id: Self { self }

    var label: String {
        switch self {
        case .app: L10n.app
        case .meetings: L10n.meetings
        case .integrations: L10n.integrations
        case .ai: L10n.ai
        case .advanced: L10n.advanced
        }
    }

    var categories: [SettingsCategory] {
        switch self {
        case .app: [.general, .appearance, .vault, .permissions, .backups, .search]
        case .meetings: [.transcription, .liveSubtitles, .screenshots]
        case .integrations: [.calendar, .cloudStorage]
        case .ai: [.modelProvider, .aiSummary]
        case .advanced: [.betaFeatures, .developer, .audioDiagnostics]
        }
    }
}
