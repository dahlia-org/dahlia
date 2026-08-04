import Foundation

/// 設定画面のカテゴリ。
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case permissions
    case transcription
    case screenshots
    case calendar
    case cloudStorage
    case modelProvider = "accounts"
    case aiSummary
    case mcp
    case betaFeatures
    case developer

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: L10n.general
        case .permissions: L10n.permissions
        case .transcription: L10n.transcription
        case .screenshots: L10n.screenshots
        case .calendar: L10n.calendar
        case .cloudStorage: L10n.export
        case .modelProvider: L10n.aiConnection
        case .aiSummary: L10n.aiSummary
        case .mcp: L10n.mcp
        case .betaFeatures: L10n.betaFeatures
        case .developer: L10n.developerSettings
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .permissions: "hand.raised"
        case .transcription: "waveform"
        case .screenshots: "photo.on.rectangle.angled"
        case .calendar: "calendar"
        case .cloudStorage: "square.and.arrow.up"
        case .modelProvider: "link"
        case .aiSummary: "sparkles"
        case .mcp: "network"
        case .betaFeatures: "testtube.2"
        case .developer: "wrench.and.screwdriver"
        }
    }
}
