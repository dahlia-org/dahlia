import Foundation

/// サイドバーで設定項目をユーザーの目的別にまとめるグループ。
enum SettingsGroup: CaseIterable, Identifiable {
    case app
    case features
    case advanced

    var id: Self { self }

    var label: String {
        switch self {
        case .app: L10n.thisMac
        case .features: L10n.features
        case .advanced: L10n.advanced
        }
    }

    var categories: [SettingsCategory] {
        switch self {
        case .app: [.general, .appearance, .permissions, .backups]
        case .features: [.workspace, .meetings, .agents, .dahliaMCP, .calendar]
        case .advanced: [.search, .betaFeatures, .audioDiagnostics]
        }
    }
}
