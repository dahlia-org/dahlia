import Foundation

/// 設定画面のカテゴリ。
enum SettingsCategory: String, CaseIterable, Identifiable {
    case accountsAndWorkspaces
    case accountPreferences
    case agents
    case workspacePreferences
    case macInference
    case general
    case dahliaAccounts
    case language
    case appearance
    /// Opens Appearance on its Event Display tab.
    case eventDisplay
    case workspace
    case permissions
    case backups
    case search
    case meetings
    /// Opens Meetings on its tab.
    case transcription
    /// Opens Meetings on its tab.
    case recordingStopDetection
    /// Opens Meetings on its tab.
    case liveSubtitles
    /// Opens Meetings on its tab.
    case screenshots
    case calendar
    /// Opens Meetings on its tab.
    case meetingLinks
    case modelProvider = "accounts"
    case aiSummary
    case mcp
    case dahliaMCP
    case instructions
    case betaFeatures
    case audioDiagnostics

    var id: String { rawValue }

    var label: String {
        switch self {
        case .accountsAndWorkspaces: L10n.serverConnections
        case .accountPreferences: L10n.accountPreferences
        case .agents: L10n.agents
        case .workspacePreferences: L10n.workspaceSettings
        case .macInference: L10n.macInferencePreferences
        case .general: L10n.general
        case .dahliaAccounts: L10n.dahliaAccount
        case .language: L10n.language
        case .appearance: L10n.appearance
        case .eventDisplay: L10n.appearanceEventDisplay
        case .workspace: L10n.workspace
        case .permissions: L10n.permissions
        case .backups: L10n.dataProtection
        case .search: L10n.search
        case .meetings: L10n.meetings
        case .transcription: L10n.transcription
        case .recordingStopDetection: L10n.recordingStopDetection
        case .liveSubtitles: L10n.liveSubtitles
        case .screenshots: L10n.screenshots
        case .calendar: L10n.calendar
        case .meetingLinks: L10n.meetingLinks
        case .modelProvider: L10n.modelProvider
        case .aiSummary: L10n.transcriptionAndSummary
        case .mcp: L10n.mcp
        case .dahliaMCP: L10n.dahliaMCP
        case .instructions: L10n.instructions
        case .betaFeatures: L10n.betaFeatures
        case .audioDiagnostics: L10n.diagnostics
        }
    }

    var systemImage: String {
        switch self {
        case .accountsAndWorkspaces: "brain"
        case .accountPreferences: "text.badge.star"
        case .agents: "sparkles"
        case .workspacePreferences: "globe"
        case .macInference: "sparkles"
        case .general: "gearshape"
        case .dahliaAccounts: "person.crop.circle"
        case .language: "globe"
        case .appearance: "sun.max"
        case .eventDisplay: "calendar"
        case .workspace: ProjectIcon.workspace.systemImageName
        case .permissions: "hand.raised"
        case .backups: "lock.shield"
        case .search: "magnifyingglass"
        case .meetings: "waveform.badge.microphone"
        case .transcription: "waveform.and.mic"
        case .recordingStopDetection: "stop.circle"
        case .liveSubtitles: "captions.bubble"
        case .screenshots: "photo.on.rectangle.angled"
        case .calendar: "calendar"
        case .meetingLinks: "link"
        case .modelProvider: "sparkles"
        case .aiSummary: "list.bullet.clipboard"
        case .mcp: "network"
        case .dahliaMCP: "point.3.connected.trianglepath.dotted"
        case .instructions: "list.bullet.clipboard"
        case .betaFeatures: "testtube.2"
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
                L10n.appLanguages,
                L10n.notifications,
                L10n.meetingNotifications,
                L10n.notificationConditions,
                L10n.audioInput,
                L10n.externalMicrophoneEchoCancellation,
            ]
        case .accountPreferences:
            [
                L10n.settingsSummaryOutput,
                L10n.summaryStyle,
                L10n.model,
                L10n.reasoningEffort,
                L10n.processingLocation,
                L10n.summaryModel,
                L10n.imageAnalysis,
                L10n.imageAnalysisEnabled,
                "AI",
            ]
        case .agents:
            // The services Unity AI Gateway commonly offers; a workspace lists its own when a server is added.
            [
                L10n.unityGatewayMCPs,
                L10n.mcp,
                L10n.unityGateway,
                "Databricks",
                L10n.useManagedPi,
                "Pi",
                L10n.agentProviders,
                L10n.agentEnvironment,
                "ChatGPT",
                "OpenAI",
                "Anthropic",
                "Claude",
            ]
                + Self.accountPreferences.searchTerms + Self.macInference.searchTerms
                + ["Gmail", "Google Calendar", "Google Drive", "Slack", "GitHub", "Atlassian", "Jira", "Confluence", "Microsoft 365"]
        case .workspace:
            [L10n.workspace, L10n.generatedContentLanguage, L10n.summaryOutputLanguage]
        case .macInference:
            [L10n.modelProvider, L10n.model, L10n.reasoningEffort, "AI", "ChatGPT", "OpenAI", "Anthropic", "Claude", "Databricks", L10n.unityGateway]
        case .meetings:
            [
                L10n.transcription,
                L10n.transcriptionLanguage,
                L10n.automaticDetectionLanguagesTitle,
                L10n.transcriptionModel,
                L10n.export,
                L10n.liveTranscriptDraft,
                L10n.recordingStopDetection,
                L10n.automaticRecordingStop,
                L10n.automaticMeetingEndRecordingStop,
                L10n.automaticRecordingProcessing,
                L10n.liveSubtitles,
                L10n.liveSubtitleLanguage,
                L10n.liveSubtitleTranslation,
                L10n.translationTargetLanguage,
                L10n.includeMicrophone,
                L10n.screenshots,
                L10n.automaticScreenshots,
                L10n.adaptiveScreenshotInterval,
                L10n.screenshotInterval,
                L10n.sharedContent,
                L10n.meetingLinks,
                L10n.meetingLinkApplications,
                L10n.meetingLinkServiceOverrides,
                "Google Meet",
                "Zoom",
                "Teams",
                "Slack",
            ]
        case .dahliaMCP:
            [L10n.mcp, L10n.mcpPreview, L10n.mcpConfigurationOutput, "Claude", "Codex"]
        case .calendar:
            ["Google", L10n.googleCalendar, L10n.macOSCalendar, L10n.calendarSources]
        case .appearance:
            [
                L10n.display,
                L10n.appLanguage,
                L10n.textSize,
                L10n.sidebarDisplayStyle,
                L10n.appearanceMenuBar,
                L10n.menuBarCalendar,
                L10n.appearanceEventDisplay,
                L10n.calendar,
                L10n.calendarEventsToInclude,
            ]
        case .accountsAndWorkspaces:
            [L10n.accountPreferences, L10n.macInferencePreferences]
                + Self.accountPreferences.searchTerms + Self.macInference.searchTerms
        case .backups:
            [
                L10n.screenshotCacheLimit,
                L10n.backups,
                L10n.workspace,
                L10n.createBackup,
                L10n.importBackup,
                L10n.restoreBackup,
                L10n.serverContentRetention,
                L10n.serverContentRetentionDays,
                L10n.forever,
                L10n.batchAudioRetentionPeriod,
                L10n.batchTranscriptionStallTimeout,
            ]
        case .search:
            [L10n.fullTextSearch, L10n.searchRanking, L10n.rebuildFullTextSearch]
        default: []
        }
    }
}
