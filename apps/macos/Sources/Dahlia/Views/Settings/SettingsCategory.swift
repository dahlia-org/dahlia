import Foundation

/// 設定画面のカテゴリ。
enum SettingsCategory: String, CaseIterable, Identifiable {
    case accountsAndWorkspaces
    case accountPreferences
    case providers
    case agents
    case skills
    case memory
    case workspacePreferences
    case macInference
    case general
    case dahliaAccounts
    case language
    case appearance
    /// Opens Calendar on its Event Display tab.
    case eventDisplay
    case workspace
    case permissions
    case backups
    case storage
    case search
    case meetings
    /// Opens the corresponding step in the meeting processing flow.
    case transcription
    /// Opens the corresponding step in the meeting processing flow.
    case recordingStopDetection
    /// Opens the corresponding step in the meeting processing flow.
    case liveSubtitles
    /// Opens the corresponding step in the meeting processing flow.
    case screenshots
    case calendar
    case meetingLinks
    case modelProvider = "accounts"
    case aiSummary
    case mcp
    case dahliaMCP
    case instructions
    case audioDiagnostics

    var id: String { rawValue }

    var label: String {
        switch self {
        case .accountsAndWorkspaces: L10n.serverConnections
        case .accountPreferences: L10n.accountPreferences
        case .providers: L10n.providerAccounts
        case .agents: L10n.agentAdvancedSettings
        case .skills: L10n.agentSkills
        case .memory: L10n.agentMemory
        case .workspacePreferences: L10n.workspaceSettings
        case .macInference: L10n.macInferencePreferences
        case .general: L10n.general
        case .dahliaAccounts: L10n.dahliaAccount
        case .language: L10n.language
        case .appearance: L10n.appearance
        case .eventDisplay: L10n.appearanceEventDisplay
        case .workspace: L10n.workspace
        case .permissions: L10n.permissions
        case .storage: L10n.cloudStorage
        case .backups: L10n.dataProtection
        case .search: L10n.search
        case .meetings: L10n.meetings
        case .transcription: L10n.transcription
        case .recordingStopDetection: L10n.recordingStopDetection
        case .liveSubtitles: L10n.liveSubtitles
        case .screenshots: L10n.screenshots
        case .calendar: L10n.calendar
        case .meetingLinks: L10n.meetingLinks
        case .modelProvider: L10n.agentModels
        case .aiSummary: L10n.transcriptionAndSummary
        case .mcp: L10n.agentMCPs
        case .dahliaMCP: L10n.dahliaMCP
        case .instructions: L10n.instructions
        case .audioDiagnostics: L10n.diagnostics
        }
    }

    var systemImage: String {
        switch self {
        case .accountsAndWorkspaces: "brain"
        case .accountPreferences: "text.badge.star"
        case .providers: "person.badge.key"
        case .agents: "slider.horizontal.3"
        case .skills: "book.closed"
        case .memory: "brain.head.profile"
        case .workspacePreferences: "globe"
        case .macInference: "sparkles"
        case .general: "gearshape"
        case .dahliaAccounts: "person.crop.circle"
        case .language: "globe"
        case .appearance: "sun.max"
        case .eventDisplay: "calendar"
        case .workspace: ProjectIcon.workspace.systemImageName
        case .permissions: "hand.raised"
        case .storage: "externaldrive"
        case .backups: "lock.shield"
        case .search: "magnifyingglass"
        case .meetings: "waveform.badge.microphone"
        case .transcription: "waveform.and.mic"
        case .recordingStopDetection: "stop.circle"
        case .liveSubtitles: "captions.bubble"
        case .screenshots: "photo.on.rectangle.angled"
        case .calendar: "calendar"
        case .meetingLinks: "link"
        case .modelProvider: "brain"
        case .aiSummary: "list.bullet.clipboard"
        case .mcp: "point.3.connected.trianglepath.dotted"
        case .dahliaMCP: "point.3.connected.trianglepath.dotted"
        case .instructions: "list.bullet.clipboard"
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
        case .providers:
            [
                L10n.addProvider, L10n.renameProviderAccount, L10n.signInAgain, L10n.signOut,
                "ChatGPT", "OpenAI", "Anthropic", "Claude", "Databricks", L10n.unityGateway, "Google", L10n.googleCalendar, L10n.googleDrive,
            ]
        case .agents:
            [L10n.useManagedPi, "Pi", L10n.agentEnvironment, L10n.agentPackages, "npm", L10n.agentSchedules, L10n.agentSecurity]
        case .modelProvider:
            [L10n.agentProviders, L10n.unityGateway, "Databricks", "ChatGPT", "OpenAI", "Anthropic", "Claude"]
                + Self.accountPreferences.searchTerms + Self.macInference.searchTerms
        case .mcp:
            // The services Unity AI Gateway commonly offers; a workspace lists its own when a server is added.
            [L10n.unityGatewayMCPs, L10n.mcp, L10n.unityGateway, "Databricks"]
                + ["Gmail", "Google Calendar", "Google Drive", "Slack", "GitHub", "Atlassian", "Jira", "Confluence", "Microsoft 365"]
        case .skills:
            [
                L10n.skillsTabManage, L10n.skillsTabReadOnly, L10n.agentSkillHistory, L10n.skillsTabCuration, L10n.agentSkillCurator,
                L10n.agentCuratorInterval,
                L10n.agentCuratorArchiveAfter, L10n.agentCuratorConsolidate, L10n.agentSkillReviewEnabled, L10n.agentArchivedSkills,
                L10n.agentSkillLock, L10n.agentSkillPin, "Curator", L10n.agentSkillOptimizer, L10n.agentSkillReviewSection,
                L10n.agentCuratorRuns, L10n.agentOptimizerRuns,
                "GEPA",
            ]
        case .memory:
            [L10n.agentMemoryEnabled, L10n.agentMemoryUser, L10n.agentMemoryEnvironment, L10n.agentMemoryReviewEnabled, L10n.agentMemoryClear]
        case .workspace:
            [L10n.workspace, L10n.generatedContentLanguage, L10n.summaryOutputLanguage]
        case .macInference:
            [L10n.modelProvider, L10n.model, L10n.reasoningEffort, "AI", "ChatGPT", "OpenAI", "Anthropic", "Claude", "Databricks", L10n.unityGateway]
        case .meetings:
            [
                L10n.language,
                L10n.meetingDataProcessing,
                L10n.meetingProcessingFlowTitle,
                L10n.meetingProcessingScreenshotCapture,
                L10n.meetingProcessingLiveTranscription,
                L10n.meetingProcessingImageRecognition,
                L10n.imageAnalysis,
                L10n.generatedContentLanguage,
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
                L10n.liveTranscriptionLanguage,
                L10n.liveSubtitleTranslation,
                L10n.translationTargetLanguage,
                L10n.includeMicrophone,
                L10n.screenshots,
                L10n.automaticScreenshots,
                L10n.adaptiveScreenshotInterval,
                L10n.screenshotInterval,
                L10n.sharedContent,
            ]
        case .meetingLinks:
            [
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
            ["Google", L10n.googleCalendar, L10n.macOSCalendar, L10n.calendarSources, L10n.appearanceEventDisplay, L10n.calendarEventsToInclude]
        case .appearance:
            [
                L10n.display,
                L10n.lightMode,
                L10n.darkMode,
                L10n.appLanguage,
                L10n.textSize,
                L10n.sidebarDisplayStyle,
                L10n.appearanceMenuBar,
                L10n.menuBarCalendar,
            ]
        case .accountsAndWorkspaces:
            [L10n.accountPreferences, L10n.macInferencePreferences]
                + Self.accountPreferences.searchTerms + Self.macInference.searchTerms
        case .storage:
            [L10n.storageDefaultFolder, L10n.databricksCatalogSchema, "Google Drive", "Databricks", "Unity Catalog", "UC", "Volume", "catalog.schema"]
        case .backups:
            [
                L10n.backups,
                L10n.workspace,
                L10n.createBackup,
                L10n.importBackup,
                L10n.restoreBackup,
                L10n.batchAudioRetentionPeriod,
                L10n.batchTranscriptionStallTimeout,
            ]
        case .search:
            [
                L10n.fullTextSearch,
                L10n.searchRanking,
                L10n.rebuildFullTextSearch,
                L10n.searchDictionary,
                L10n.searchUserDictionary,
                "Lindera",
                "IPADIC",
                "NEologd",
                "CSV",
            ]
        default: []
        }
    }
}
