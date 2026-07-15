import Foundation

/// サイドバーで設定項目をユーザーの目的別にまとめるグループ。
enum SettingsGroup: CaseIterable, Identifiable {
    case app
    case recording
    case integrations
    case ai
    case advanced

    var id: Self { self }

    var label: String {
        switch self {
        case .app: L10n.app
        case .recording: L10n.recording
        case .integrations: L10n.integrations
        case .ai: L10n.ai
        case .advanced: L10n.advanced
        }
    }

    var categories: [SettingsCategory] {
        switch self {
        case .app: [.general]
        case .recording: [.transcription, .screenshots]
        case .integrations: [.calendar, .cloudStorage]
        case .ai: [.modelProvider, .aiSummary, .meetingDataAccess, .instructions]
        case .advanced: [.developer, .audioDiagnostics]
        }
    }
}
