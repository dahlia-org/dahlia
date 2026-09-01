import Foundation

/// 設定画面のカテゴリ。
enum SettingsCategory: String, CaseIterable, Identifiable {
    case accountsAndVaults
    case general
    case dahliaAccounts
    case language
    case appearance
    case vault
    case permissions
    case backups
    case search
    case transcription
    case liveSubtitles
    case screenshots
    case calendar
    case cloudStorage
    case modelProvider = "accounts"
    case aiSummary
    case mcp
    case instructions
    case betaFeatures
    case developer
    case audioDiagnostics

    var id: String { rawValue }

    var label: String {
        switch self {
        case .accountsAndVaults: L10n.accountsAndVaults
        case .general: L10n.general
        case .dahliaAccounts: L10n.dahliaAccount
        case .language: L10n.language
        case .appearance: L10n.appearance
        case .vault: L10n.vault
        case .permissions: L10n.permissions
        case .backups: L10n.backups
        case .search: L10n.search
        case .transcription: L10n.transcription
        case .liveSubtitles: L10n.liveSubtitles
        case .screenshots: L10n.screenshots
        case .calendar: L10n.calendar
        case .cloudStorage: L10n.export
        case .modelProvider: L10n.modelProvider
        case .aiSummary: L10n.summary
        case .mcp: L10n.mcp
        case .instructions: L10n.instructions
        case .betaFeatures: L10n.betaFeatures
        case .developer: L10n.developerSettings
        case .audioDiagnostics: L10n.diagnostics
        }
    }

    var systemImage: String {
        switch self {
        case .accountsAndVaults: "person.2"
        case .general: "gearshape"
        case .dahliaAccounts: "person.crop.circle"
        case .language: "globe"
        case .appearance: "sun.max"
        case .vault: "externaldrive"
        case .permissions: "hand.raised"
        case .backups: "externaldrive.badge.timemachine"
        case .search: "magnifyingglass"
        case .transcription: "waveform"
        case .liveSubtitles: "captions.bubble"
        case .screenshots: "photo.on.rectangle.angled"
        case .calendar: "calendar"
        case .cloudStorage: "square.and.arrow.up"
        case .modelProvider: "sparkles"
        case .aiSummary: "list.bullet.clipboard"
        case .mcp: "network"
        case .instructions: "list.bullet.clipboard"
        case .betaFeatures: "testtube.2"
        case .developer: "wrench.and.screwdriver"
        case .audioDiagnostics: "stethoscope"
        }
    }
}
