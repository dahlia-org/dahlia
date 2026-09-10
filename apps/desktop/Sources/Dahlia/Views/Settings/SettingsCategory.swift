import Foundation

/// 設定画面のカテゴリ。
enum SettingsCategory: String, CaseIterable, Identifiable {
    case accountsAndVaults
    case accountPreferences
    case macInference
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
        case .accountPreferences: L10n.generationAndAnalysis
        case .macInference: L10n.macInferencePreferences
        case .general: L10n.general
        case .dahliaAccounts: L10n.dahliaAccount
        case .language: L10n.language
        case .appearance: L10n.appearance
        case .vault: L10n.vault
        case .permissions: L10n.permissions
        case .backups: L10n.backups
        case .search: L10n.search
        case .transcription: L10n.recordingSettings
        case .liveSubtitles: L10n.liveSubtitles
        case .screenshots: L10n.screenshots
        case .calendar: L10n.calendar
        case .cloudStorage: L10n.export
        case .modelProvider: L10n.modelProvider
        case .aiSummary: L10n.transcriptionAndSummary
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
        case .accountPreferences: "text.badge.star"
        case .macInference: "sparkles"
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

    /// Search the controls as well as page titles, without loading settings views or services.
    func matches(_ query: String) -> Bool {
        let text = ([label] + searchTerms).joined(separator: " ")
        return query.split(whereSeparator: \.isWhitespace).allSatisfy {
            text.localizedStandardContains(String($0))
        }
    }

    private var searchTerms: [String] {
        switch self {
        case .general:
            [
                L10n.language,
                L10n.appearance,
                L10n.appLanguage,
                L10n.appLanguages,
                L10n.notifications,
                L10n.meetingNotifications,
                L10n.notificationConditions,
                L10n.sidebarDisplayStyle,
            ]
        case .accountPreferences:
            [
                L10n.accountPreferences,
                L10n.transcriptionAndSummary,
                L10n.summaryStyle,
                L10n.summaryOutputLanguage,
                L10n.processingLocation,
                L10n.imageAnalysisLanguages,
                L10n.summaryModel,
                L10n.transcriptionModel,
                "AI",
            ]
        case .macInference:
            [L10n.modelProvider, L10n.model, L10n.reasoningEffort, "AI", "ChatGPT", "Codex", "Databricks"]
        case .transcription:
            [
                L10n.transcription,
                L10n.transcriptionLanguage,
                L10n.automaticRecordingStop,
                L10n.automaticRecordingProcessing,
                L10n.batchAudioRetentionPeriod,
                L10n.batchTranscriptionStallTimeout,
                L10n.audioInput,
                L10n.externalMicrophoneEchoCancellation,
                L10n.export,
            ]
        case .liveSubtitles:
            [L10n.liveSubtitleLanguage, L10n.liveSubtitleTranslation, L10n.translationTargetLanguage, L10n.includeMicrophone]
        case .screenshots:
            [L10n.automaticScreenshots, L10n.screenshotCacheLimit, L10n.screenshotInterval, L10n.sharedContent, L10n.imageTextLanguages]
        case .calendar:
            ["Google", L10n.macOSCalendar, L10n.calendarSources, L10n.menuBarCalendar, L10n.notifications]
        case .cloudStorage:
            ["Google", L10n.googleDrive, L10n.googleDriveExportFolder]
        case .accountsAndVaults:
            [L10n.account, L10n.vault, L10n.dahliaSignIn, L10n.dahliaServer, L10n.dahliaCloud]
        case .backups:
            [L10n.vault, L10n.createBackup, L10n.importBackup, L10n.restoreBackup]
        case .search:
            [L10n.fullTextSearch, L10n.searchRanking, L10n.rebuildFullTextSearch]
        default: []
        }
    }
}
