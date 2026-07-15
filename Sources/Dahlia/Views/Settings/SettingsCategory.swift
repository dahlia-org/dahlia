import Foundation

/// 設定項目。rawValue は保存済みの選択状態との互換性のため維持する。
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case transcription
    case screenshots
    case calendar
    case cloudStorage
    case modelProvider = "accounts"
    case aiSummary
    case meetingDataAccess
    case instructions
    case developer
    case audioDiagnostics

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: L10n.general
        case .transcription: L10n.transcription
        case .screenshots: L10n.screenshots
        case .calendar: L10n.calendar
        case .cloudStorage: L10n.export
        case .modelProvider: L10n.aiConnection
        case .aiSummary: L10n.aiSummary
        case .meetingDataAccess: L10n.meetingDataAccess
        case .instructions: L10n.instructions
        case .developer: L10n.developerSettings
        case .audioDiagnostics: L10n.diagnostics
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .transcription: "waveform"
        case .screenshots: "photo.on.rectangle.angled"
        case .calendar: "calendar"
        case .cloudStorage: "square.and.arrow.up"
        case .modelProvider: "link"
        case .aiSummary: "sparkles"
        case .meetingDataAccess: "server.rack"
        case .instructions: "list.bullet.clipboard"
        case .developer: "wrench.and.screwdriver"
        case .audioDiagnostics: "stethoscope"
        }
    }
}
