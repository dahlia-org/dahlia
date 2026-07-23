import Foundation

/// 設定画面のカテゴリ。
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case permissions
    case backups
    case transcription
    case screenshots
    case calendar
    case cloudStorage
    case modelProvider = "accounts"
    case aiSummary
    case mcp
    case instructions
    case developer
    case audioDiagnostics

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: L10n.general
        case .permissions: L10n.permissions
        case .backups: L10n.backups
        case .transcription: L10n.transcription
        case .screenshots: L10n.screenshots
        case .calendar: L10n.calendar
        case .cloudStorage: L10n.export
        case .modelProvider: L10n.aiConnection
        case .aiSummary: L10n.aiSummary
        case .mcp: L10n.mcp
        case .instructions: L10n.instructions
        case .developer: L10n.developerSettings
        case .audioDiagnostics: L10n.diagnostics
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .permissions: "hand.raised"
        case .backups: "externaldrive.badge.timemachine"
        case .transcription: "waveform"
        case .screenshots: "photo.on.rectangle.angled"
        case .calendar: "calendar"
        case .cloudStorage: "square.and.arrow.up"
        case .modelProvider: "link"
        case .aiSummary: "sparkles"
        case .mcp: "network"
        case .instructions: "list.bullet.clipboard"
        case .developer: "wrench.and.screwdriver"
        case .audioDiagnostics: "stethoscope"
        }
    }
}
