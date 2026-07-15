import Foundation

/// ローカライズ文字列への型安全なアクセスを提供する。
enum L10n {
    /// キャッシュ済みの Bundle と、その生成元の言語 rawValue。
    /// 言語設定が変わらない限り Bundle を再生成しない。
    private nonisolated(unsafe) static var cachedBundle: Bundle = .appModule
    private nonisolated(unsafe) static var cachedLanguageRaw = ""

    /// 選択された表示言語に対応する Bundle を返す。
    /// UserDefaults から直接読み取ることで @MainActor 制約を回避する。
    private nonisolated static var bundle: Bundle {
        let rawValue = UserDefaults.standard.string(forKey: AppLanguage.userDefaultsKey) ?? AppLanguage.system.rawValue
        if rawValue == cachedLanguageRaw { return cachedBundle }
        let resolved: Bundle = if let language = AppLanguage(rawValue: rawValue),
                                  let lprojName = language.lprojName,
                                  let path = Bundle.appModule.path(forResource: lprojName, ofType: "lproj"),
                                  let lprojBundle = Bundle(path: path) {
            lprojBundle
        } else {
            .appModule
        }
        cachedLanguageRaw = rawValue
        cachedBundle = resolved
        return resolved
    }

    // MARK: - Common

    static var delete: String { String(localized: "Delete", bundle: bundle) }
    static var rename: String { String(localized: "Rename", bundle: bundle) }
    static var retry: String { String(localized: "Retry", bundle: bundle) }
    static var create: String { String(localized: "Create", bundle: bundle) }
    static var auto: String { String(localized: "Auto", bundle: bundle) }
    static var apply: String { String(localized: "Apply", bundle: bundle) }
    static var clear: String { String(localized: "Clear", bundle: bundle) }
    static var close: String { String(localized: "Close", bundle: bundle) }
    static var search: String { String(localized: "Search", bundle: bundle) }
    static var actions: String { String(localized: "Actions", bundle: bundle) }
    static var status: String { String(localized: "Status", bundle: bundle) }
    static var dahlia: String { String(localized: "Dahlia", bundle: bundle) }
    static var anotherDahliaInstanceTitle: String { String(localized: "Dahlia Is Already Running", bundle: bundle) }
    static var anotherDahliaInstanceMessage: String { String(
        localized: "Another Dahlia process is already using the recording database. This process will now quit.",
        bundle: bundle
    ) }
    static var recordingStorageUnavailable: String { String(
        localized: "The recording storage is unavailable.",
        bundle: bundle
    ) }
    static var recordingAudioSessionActive: String { String(
        localized: "The recording is still active and cannot be changed.",
        bundle: bundle
    ) }
    static var recordingAudioAmbiguous: String { String(
        localized: "Multiple recording files exist and Dahlia cannot safely choose one.",
        bundle: bundle
    ) }
    static var recordingAudioDiskSpaceLow: String { String(
        localized: "Recording stopped because less than 1 GB of safe disk space remains.",
        bundle: bundle
    ) }
    static var recordingAudioIntegrityMismatch: String { String(
        localized: "The recording failed its integrity check.",
        bundle: bundle
    ) }
    static var recordingAudioInvalidPath: String { String(
        localized: "Dahlia refused an unsafe recording file path.",
        bundle: bundle
    ) }
    static var recordingAudioInvalidState: String { String(
        localized: "The recording is not in a state that allows this operation.",
        bundle: bundle
    ) }
    static var recordingAudioMissingSessionLease: String { String(
        localized: "The recording session lease is not held.",
        bundle: bundle
    ) }
    static var recordingAudioMissing: String { String(
        localized: "A recording file is missing.",
        bundle: bundle
    ) }
    static var recordingAudioFinalizationDelayed: String { String(
        localized: "Recording continues, but durable storage is temporarily delayed.",
        bundle: bundle
    ) }
    static var recordingAudioSafetyLimit: String { String(
        localized: "Recording stopped because the active segment reached its safety limit.",
        bundle: bundle
    ) }
    static var recordingAudioWriteQueueOverflow: String { String(
        localized: "Recording stopped because audio arrived faster than it could be stored.",
        bundle: bundle
    ) }
    static func recordingAudioStoppedWithDurableTime(reason: String, durableTime: String) -> String {
        String(
            localized: "\(reason) Audio through \(durableTime) is durable for every required source.",
            bundle: bundle
        )
    }

    static func recordingAudioRecoveryIncomplete(durableTime: String) -> String {
        String(
            localized: "The interrupted recording contains a damaged or missing interval. Audio through \(durableTime) is durable for every required source.",
            bundle: bundle
        )
    }

    static var language: String { String(localized: "Language", bundle: bundle) }
    static var join: String { String(localized: "Join", bundle: bundle) }
    static var expand: String { String(localized: "Expand", bundle: bundle) }
    static var collapse: String { String(localized: "Collapse", bundle: bundle) }
    static var back: String { String(localized: "Back", bundle: bundle) }
    static var forward: String { String(localized: "Forward", bundle: bundle) }
    static var showSidebar: String { String(localized: "Show Sidebar", bundle: bundle) }
    static var hideSidebar: String { String(localized: "Hide Sidebar", bundle: bundle) }

    // MARK: - Sidebar

    static var home: String { String(localized: "Home", bundle: bundle) }
    static var goodMorning: String { String(localized: "Good morning", bundle: bundle) }
    static var goodAfternoon: String { String(localized: "Good afternoon", bundle: bundle) }
    static var goodEvening: String { String(localized: "Good evening", bundle: bundle) }
    static var meetings: String { String(localized: "Meetings", bundle: bundle) }
    static var projects: String { String(localized: "Projects", bundle: bundle) }
    static var projectManagement: String { String(localized: "Project Management", bundle: bundle) }
    static var instructions: String { String(localized: "Instructions", bundle: bundle) }
    static var context: String { String(localized: "Context", bundle: bundle) }
    static var actionItems: String { String(localized: "Action Items", bundle: bundle) }
    static var me: String { String(localized: "Me", bundle: bundle) }
    static var ask: String { String(localized: "Ask", bundle: bundle) }
    static var newProject: String { String(localized: "New Project", bundle: bundle) }
    static var newSubproject: String { String(localized: "New Subproject", bundle: bundle) }
    static var newTopLevelProject: String { String(localized: "New Project at Vault Top", bundle: bundle) }

    static func projectCreationLocation(_ name: String) -> String {
        String(localized: "Create a subproject inside \(name).", bundle: bundle)
    }

    static var projectCreationAtVaultTop: String { String(
        localized: "Create a project at the top level of the vault.",
        bundle: bundle
    ) }
    static var projectCreationFailed: String { String(localized: "Could Not Create Project", bundle: bundle) }
    static var projectCreationFailedDescription: String { String(localized: "The project folder could not be created.", bundle: bundle) }
    static var newMeeting: String { String(localized: "New meeting", bundle: bundle) }
    static var projectName: String { String(localized: "Project Name", bundle: bundle) }
    static var renameProject: String { String(localized: "Rename Project", bundle: bundle) }
    static var projectNameHelp: String { String(
        localized: "Renaming also updates the project folder and all subprojects.",
        bundle: bundle
    ) }
    static var location: String { String(localized: "Location", bundle: bundle) }
    static var latestMeeting: String { String(localized: "Latest Meeting", bundle: bundle) }
    static var openInFinder: String { String(localized: "Open in Finder", bundle: bundle) }
    static var openInObsidian: String { String(localized: "Open in Obsidian", bundle: bundle) }
    static var openInBrowser: String { String(localized: "Open in Browser", bundle: bundle) }
    static var recreateFolder: String { String(localized: "Recreate Folder", bundle: bundle) }
    static var folderMissing: String { String(localized: "Folder missing on disk", bundle: bundle) }
    static var homeUnderConstruction: String { String(localized: "Home is under construction.", bundle: bundle) }
    static var actionItemsComingSoon: String { String(localized: "Action items will appear here.", bundle: bundle) }
    static var selectProjectFromProjects: String { String(localized: "Select a project from Projects.", bundle: bundle) }
    static var openProjects: String { String(localized: "Open Projects", bundle: bundle) }
    static var title: String { String(localized: "Title", bundle: bundle) }
    static var all: String { String(localized: "All", bundle: bundle) }
    static var filter: String { String(localized: "Filter", bundle: bundle) }
    static var searchFilters: String { String(localized: "Search filters...", bundle: bundle) }
    static var tags: String { String(localized: "Tags", bundle: bundle) }
    static var assignedToMe: String { String(localized: "Assigned to me", bundle: bundle) }
    static var completed: String { String(localized: "Completed", bundle: bundle) }
    static var waiting: String { String(localized: "Waiting", bundle: bundle) }
    static var skipped: String { String(localized: "Skipped", bundle: bundle) }
    static var projectIs: String { String(localized: "Project is", bundle: bundle) }
    static var tagIs: String { String(localized: "Tag is", bundle: bundle) }
    static var today: String { String(localized: "Today", bundle: bundle) }
    static var tomorrow: String { String(localized: "Tomorrow", bundle: bundle) }
    static var inProgress: String { String(localized: "In Progress", bundle: bundle) }
    static var noMeetingsYet: String { String(localized: "No meetings yet", bundle: bundle) }
    static var noMeetingsMatchFilter: String { String(localized: "No meetings match the current filter.", bundle: bundle) }
    static var searchMeetings: String { String(localized: "Search meetings...", bundle: bundle) }
    static var searchProjects: String { String(localized: "Search projects...", bundle: bundle) }
    static var moveToProject: String { String(localized: "Move to Project", bundle: bundle) }
    static var noMeetingSelected: String { String(localized: "No meeting selected", bundle: bundle) }
    static var selectMeetingDescription: String { String(localized: "Select a meeting from the sidebar.", bundle: bundle) }
    static var noProjectsYet: String { String(localized: "No projects yet", bundle: bundle) }
    static var noProjectsMatchFilter: String { String(localized: "No projects match the current filter.", bundle: bundle) }
    static var noInstructionsYet: String { String(localized: "No instructions yet", bundle: bundle) }
    static var noActionItemsYet: String { String(localized: "No action items yet", bundle: bundle) }
    static var noActionItemsMatchFilter: String { String(localized: "No action items match the current filter.", bundle: bundle) }
    static var actionItemsDescription: String { String(localized: "Action items extracted from summaries will appear here.", bundle: bundle) }
    static var missingOnDisk: String { String(localized: "Missing on Disk", bundle: bundle) }
    static func meetingCount(_ count: Int) -> String { String(localized: "\(count) meetings", bundle: bundle) }
    static var noMeetings: String { String(localized: "No meetings", bundle: bundle) }
    static var noConversationDetected: String { String(localized: "We couldn't detect any conversation in this meeting.", bundle: bundle) }
    static var recordingNow: String { String(localized: "Recording now", bundle: bundle) }
    static var transcribingNow: String { String(localized: "Transcribing now", bundle: bundle) }
    static var returnToRecordingMeeting: String { String(localized: "Return to recording meeting", bundle: bundle) }
    static var returnToTranscribingMeeting: String { String(localized: "Return to transcribing meeting", bundle: bundle) }
    static var yesterday: String { String(localized: "Yesterday", bundle: bundle) }
    static func deleteCount(_ count: Int) -> String { String(localized: "Delete \(count) items", bundle: bundle) }
    static func moveCount(_ count: Int) -> String { String(localized: "Move \(count) items", bundle: bundle) }
    static func selectedCount(_ count: Int) -> String { String(localized: "\(count) selected", bundle: bundle) }

    // MARK: - Meeting Metadata

    static var addTag: String { String(localized: "Add tag", bundle: bundle) }
    static var searchOrCreateTag: String { String(localized: "Search or create tag...", bundle: bundle) }
    static var searchOrCreateProject: String { String(localized: "Search or create project...", bundle: bundle) }
    static var addInstruction: String { String(localized: "Add Instruction", bundle: bundle) }
    static var addInstructionDescription: String { String(localized: "Create your first instruction to customize summary output.", bundle: bundle) }
    static var selectInstruction: String { String(localized: "Select Instruction", bundle: bundle) }
    static var selectInstructionDescription: String { String(localized: "Select an instruction to edit.", bundle: bundle) }
    static var useForSummary: String { String(localized: "Use for Summary", bundle: bundle) }
    static var useAutoInstructions: String { String(localized: "Use Auto", bundle: bundle) }
    static var summaryInstructionSelected: String { String(localized: "This instruction is currently used for summary generation.", bundle: bundle) }
    static var summaryInstructionNotSelected: String { String(
        localized: "This instruction is not currently used for summary generation.",
        bundle: bundle
    ) }
    static var instructionsEmptyContent: String { String(localized: "No content yet", bundle: bundle) }
    static var noResultsFound: String { String(localized: "No results found", bundle: bundle) }
    static var noProject: String { String(localized: "No project", bundle: bundle) }
    static var summaryDestinations: String { String(localized: "Summary Destinations", bundle: bundle) }
    static var summaryDestinationsDescription: String { String(
        localized: "Manage where this project's summary files are saved.",
        bundle: bundle
    ) }
    static var localSummaryFolder: String { String(localized: "Local Summary Folder", bundle: bundle) }
    static var projectDescription: String { String(localized: "Project Description", bundle: bundle) }
    static var projectDescriptionHelp: String { String(
        localized: "This description is included when summaries are generated for this project.",
        bundle: bundle
    ) }
    static var projectDescriptionPlaceholder: String { String(localized: "Describe this project...", bundle: bundle) }
    static var projectDescriptionSaveFailed: String { String(localized: "Could not save the project description.", bundle: bundle) }
    static var saving: String { String(localized: "Saving…", bundle: bundle) }
    static var saved: String { String(localized: "Saved", bundle: bundle) }
    static var dangerZone: String { String(localized: "Danger Zone", bundle: bundle) }
    static var deleteProject: String { String(localized: "Delete Project", bundle: bundle) }
    static var deleteProjectHelp: String { String(
        localized: "Deletes this project and all subprojects. The project folder is moved to the Trash.",
        bundle: bundle
    ) }

    static func deleteProjectConfirmation(_ name: String) -> String {
        String(localized: "Delete \(name)?", bundle: bundle)
    }

    static func projectDeletionSummary(projectCount: Int, meetingCount: Int) -> String {
        String(localized: "This affects \(projectCount) projects and \(meetingCount) meetings.", bundle: bundle)
    }

    static var meetingHandling: String { String(localized: "Meeting History", bundle: bundle) }
    static var moveMeetingsBeforeDeletingProject: String { String(
        localized: "Move meetings to another project",
        bundle: bundle
    ) }
    static var deleteMeetingsWithProject: String { String(
        localized: "Delete meetings and their transcripts",
        bundle: bundle
    ) }
    static var moveMeetingsTo: String { String(localized: "Move Meetings To", bundle: bundle) }
    static var noProjectMoveDestination: String { String(
        localized: "There are no other available projects to move meetings to.",
        bundle: bundle
    ) }
    static var moveAndDeleteProject: String { String(localized: "Move Meetings and Delete Project", bundle: bundle) }
    static var deleteProjectAndMeetings: String { String(localized: "Delete Project and Meetings", bundle: bundle) }
    static var projectOperationFailed: String { String(localized: "Could Not Update Project", bundle: bundle) }
    static var projectNotFound: String { String(localized: "The project could not be found.", bundle: bundle) }
    static var projectParentFolderMissing: String { String(
        localized: "The parent project folder is missing from disk.",
        bundle: bundle
    ) }
    static var invalidProjectName: String { String(
        localized: "Enter a valid project name without '/', ':', control characters, or a leading '.' or '_'.",
        bundle: bundle
    ) }
    static var projectNameTooLong: String { String(localized: "The project name is too long.", bundle: bundle) }

    static func projectAlreadyExists(_ name: String) -> String {
        String(localized: "A project named \(name) already exists in this location.", bundle: bundle)
    }

    static func projectFolderAlreadyExists(_ name: String) -> String {
        String(localized: "A folder named \(name) already exists in this location.", bundle: bundle)
    }

    static var projectFolderMissingForOperation: String { String(
        localized: "The project folder must exist before it can be renamed.",
        bundle: bundle
    ) }
    static var projectTrashLocationUnavailable: String { String(
        localized: "The project folder could not be moved to a recoverable Trash location.",
        bundle: bundle
    ) }
    static var invalidProjectMoveDestination: String { String(
        localized: "Choose an available project outside the hierarchy being deleted.",
        bundle: bundle
    ) }

    static func projectRollbackFailed(operation: String, rollback: String) -> String {
        String(
            localized: "The project operation failed (\(operation)), and Dahlia could not restore the folder (\(rollback)).",
            bundle: bundle
        )
    }

    static var selectProjectToManageDescription: String { String(
        localized: "Select a project to manage summary destinations and instructions.",
        bundle: bundle
    ) }
    static var projectManagementNoVaultDescription: String { String(
        localized: "Open a vault before managing project settings.",
        bundle: bundle
    ) }

    // MARK: - Control Panel

    static var audioSource: String { String(localized: "Audio source", bundle: bundle) }
    static var preparingSpeechRecognition: String { String(localized: "Preparing speech recognition...", bundle: bundle) }
    static var recognizing: String { String(localized: "Recognizing...", bundle: bundle) }
    static var transcription: String { String(localized: "Transcription", bundle: bundle) }
    static func segmentCount(_ count: Int) -> String { String(localized: "\(count) segments", bundle: bundle) }
    static var stop: String { String(localized: "Stop", bundle: bundle) }
    static var startRecording: String { String(localized: "Start Recording", bundle: bundle) }
    static var stopRecording: String { String(localized: "Stop Recording", bundle: bundle) }
    static var recordingSessionAlreadyActive: String { String(localized: "A recording session is already active.", bundle: bundle) }
    static var recordingSessionNotActive: String { String(localized: "No recording session is active.", bundle: bundle) }
    static var stopTranscribing: String { String(localized: "Stop transcribing", bundle: bundle) }
    static var pause: String { String(localized: "Pause", bundle: bundle) }
    static var resume: String { String(localized: "Resume", bundle: bundle) }
    static var record: String { String(localized: "Record", bundle: bundle) }
    static var export: String { String(localized: "Export", bundle: bundle) }
    static var clearTranscription: String { String(localized: "Clear transcription", bundle: bundle) }
    static var newTranscription: String { String(localized: "New Transcription", bundle: bundle) }
    static var screen: String { String(localized: "Screen", bundle: bundle) }
    static var source: String { String(localized: "Source", bundle: bundle) }
    static var notSelected: String { String(localized: "Not Selected", bundle: bundle) }
    static var entireDesktop: String { String(localized: "Entire Desktop", bundle: bundle) }
    static var takeScreenshot: String { String(localized: "Take Screenshot", bundle: bundle) }
    static var screenshotDisplayUnavailable: String { String(localized: "Display not found", bundle: bundle) }
    static var screenshotImageUnavailable: String { String(localized: "Screenshot image was unavailable", bundle: bundle) }
    static var screenshotEncodingFailed: String { String(localized: "Screenshot encoding failed", bundle: bundle) }
    static var screenshotSourceUnavailable: String { String(localized: "Screenshot source is not selected or is unavailable", bundle: bundle) }
    static func screenshotCaptureFailed(_ reason: String) -> String { String(localized: "Screenshot capture failed: \(reason)", bundle: bundle) }
    static var automaticScreenshots: String { String(localized: "Automatic Screenshots", bundle: bundle) }
    static var automaticScreenshotsDescription: String { String(
        localized: "Capture the screen during recording and save a new image when the display changes significantly.",
        bundle: bundle
    ) }
    static var automaticScreenshotsToggleDescription: String { String(
        localized: "Automatically add screenshots while recording.",
        bundle: bundle
    ) }
    static var screenshotInterval: String { String(localized: "Screenshot Interval", bundle: bundle) }
    static var screenshotIntervalDescription: String { String(
        localized: "Choose how often Dahlia checks the screen for meaningful changes.",
        bundle: bundle
    ) }
    static var screenshotChangeThreshold: String { String(localized: "Screenshot Change Threshold", bundle: bundle) }
    static var screenshotChangeThresholdDescription: String { String(
        localized: "Save a new screenshot when at least this much of the screen changes.",
        bundle: bundle
    ) }
    static func seconds(_ count: Int) -> String { String(localized: "\(count) seconds", bundle: bundle) }
    static func percent(_ count: Int) -> String { String(localized: "\(count)%", bundle: bundle) }
    static var showLiveSubtitles: String { String(localized: "Show Live Subtitles", bundle: bundle) }
    static var hideLiveSubtitles: String { String(localized: "Hide Live Subtitles", bundle: bundle) }
    static var liveSubtitles: String { String(localized: "Live Subtitles", bundle: bundle) }
    static var subtitles: String { String(localized: "Subtitles", bundle: bundle) }
    static var liveSubtitlesOnStatus: String { String(localized: "Live subtitles on", bundle: bundle) }
    static var liveSubtitlesOffStatus: String { String(localized: "Live subtitles off", bundle: bundle) }
    static var liveSubtitleOverlay: String { String(localized: "Live Subtitle Overlay", bundle: bundle) }
    static var liveSubtitleOverlayToggleDescription: String { String(
        localized: "Show live subtitles when recording starts.",
        bundle: bundle
    ) }
    static var liveSubtitleOverlayDescription: String {
        [
            String(localized: "Live subtitles are available with both real-time and batch transcription.", bundle: bundle),
            String(localized: "In batch mode, subtitles are temporary and the final transcript is created after recording stops.", bundle: bundle),
        ].joined(separator: " ")
    }

    static var systemAudioOnly: String { String(localized: "System Audio Only", bundle: bundle) }
    static var includeMicrophone: String { String(localized: "Include Microphone", bundle: bundle) }
    static var liveSubtitleSourceDescription: String { String(
        localized: "Choose whether live subtitles only show system audio or also include microphone input.",
        bundle: bundle
    ) }
    static var liveSubtitleOverlaySegmentCount: String { String(localized: "Overlay Segment Count", bundle: bundle) }
    static var liveSubtitleOverlaySegmentCountDescription: String { String(
        localized: "Choose how many recent transcript segments the live subtitle overlay shows.",
        bundle: bundle
    ) }
    static var liveSubtitleConversionFailed: String { String(
        localized: "Live subtitles stopped because the audio format could not be converted.",
        bundle: bundle
    ) }

    // MARK: - Detail Tabs

    static var summary: String { String(localized: "Summary", bundle: bundle) }
    static var notes: String { String(localized: "Notes", bundle: bundle) }
    static var notesPlaceholder: String { String(localized: "NotesPlaceholder", bundle: bundle) }
    static var screenshots: String { String(localized: "Screenshots", bundle: bundle) }
    static var transcript: String { String(localized: "Transcript", bundle: bundle) }
    static var transcriptEmpty: String { String(localized: "No transcript yet.", bundle: bundle) }
    static var batchRecordingInProgress: String { String(localized: "Recording audio for transcription after recording stops…", bundle: bundle) }
    static var batchTranscriptionAwaitingConfirmation: String { String(
        localized: "Audio is ready. Confirm the language to start transcription.",
        bundle: bundle
    ) }
    static var reviewBatchTranscription: String { String(localized: "Review and Start", bundle: bundle) }
    static var batchTranscriptionQueued: String { String(localized: "Waiting to transcribe the recording…", bundle: bundle) }
    static var batchTranscriptionRunning: String { String(localized: "Creating a high-accuracy transcript…", bundle: bundle) }
    static var batchTranscriptionCompleted: String { String(localized: "High-accuracy transcription completed.", bundle: bundle) }
    static func batchTranscriptionFailed(_ reason: String) -> String {
        String(localized: "Batch transcription failed: \(reason)", bundle: bundle)
    }

    static var retryBatchTranscription: String { String(localized: "Retry Batch Transcription", bundle: bundle) }
    static var batchTranscriptionConfirmationTitle: String { String(localized: "Start batch transcription?", bundle: bundle) }
    static var batchTranscriptionConfirmationDescription: String { String(
        // swiftlint:disable:next line_length
        localized: "The selected language is used for single-language recordings. Language changes made during recording are preserved. The audio is kept until transcription succeeds.",
        bundle: bundle
    ) }
    static var deleteBatchAudioAfterTranscription: String { String(
        localized: "Delete Recording Files After Transcription",
        bundle: bundle
    ) }
    static var deleteBatchAudioAfterTranscriptionDescription: String { String(
        localized: "Delete the recording files after batch transcription succeeds. They are kept if transcription fails.",
        bundle: bundle
    ) }
    static var generateSummaryAfterBatchTranscription: String { String(
        localized: "Generate Summary After Transcription",
        bundle: bundle
    ) }
    static var generateSummaryAfterBatchTranscriptionDescription: String { String(
        localized: "Automatically generate a summary when batch transcription succeeds.",
        bundle: bundle
    ) }
    static var summaryAndExport: String { String(localized: "Summary and Export", bundle: bundle) }
    static var exportBatchSummaryToVault: String { String(
        localized: "Export Summary to Vault",
        bundle: bundle
    ) }
    static var exportBatchSummaryToVaultDescription: String { String(
        localized: "Write the generated summary and related files to the current Vault.",
        bundle: bundle
    ) }
    static var exportBatchSummaryToGoogleDocs: String { String(
        localized: "Export Summary to Google Docs",
        bundle: bundle
    ) }
    static var exportBatchSummaryToGoogleDocsDescription: String { String(
        localized: "Export the generated summary to the configured Google Docs folder.",
        bundle: bundle
    ) }
    static var later: String { String(localized: "Later", bundle: bundle) }
    static var discardFailedBatchRecording: String { String(localized: "Discard Failed Recording", bundle: bundle) }
    static var discardFailedBatchRecordingConfirmation: String { String(localized: "Discard this failed recording?", bundle: bundle) }
    static var discardFailedBatchRecordingDescription: String { String(
        localized: "The untranscribed audio will be deleted. Existing transcript content will be kept.",
        bundle: bundle
    ) }
    static var cancel: String { String(localized: "Cancel", bundle: bundle) }
    static var batchAudioBufferInvalid: String { String(localized: "The recorded audio format is invalid.", bundle: bundle) }
    static var batchAudioBufferOverflow: String { String(
        localized: "The audio writer could not keep up with the recording.",
        bundle: bundle
    ) }
    static var batchAudioWriterClosed: String { String(
        localized: "The audio writer was closed before the buffer was saved.",
        bundle: bundle
    ) }
    static func batchAudioWriteFailed(_ reason: String) -> String {
        String(localized: "Could not save the recording: \(reason)", bundle: bundle)
    }

    static var batchAudioFormatUnavailable: String { String(localized: "No compatible audio format is available.", bundle: bundle) }
    static var batchAudioRangeInvalid: String { String(localized: "The recorded audio range is invalid or damaged.", bundle: bundle) }
    static var batchAnalysisDidNotAdvance: String { String(localized: "Speech analysis could not read the recorded audio.", bundle: bundle) }
    static var assignee: String { String(localized: "Assignee", bundle: bundle) }
    static var assignToMe: String { String(localized: "Assign to me", bundle: bundle) }
    static var editAssignee: String { String(localized: "Edit assignee", bundle: bundle) }
    static var markActionItemComplete: String { String(localized: "Mark action item complete", bundle: bundle) }
    static var markActionItemIncomplete: String { String(localized: "Mark action item incomplete", bundle: bundle) }

    // MARK: - Audio Source Mode

    static var microphone: String { String(localized: "Microphone", bundle: bundle) }
    static var mic: String { String(localized: "Mic", bundle: bundle) }
    static var system: String { String(localized: "System", bundle: bundle) }
    static var systemAudio: String { String(localized: "System Audio", bundle: bundle) }
    static var both: String { String(localized: "Both", bundle: bundle) }
    static var none: String { String(localized: "None", bundle: bundle) }
    static var sameAsSystem: String { String(localized: "Same as System", bundle: bundle) }
    static func sameAsSystem(_ deviceName: String) -> String { String(localized: "Same as System (\(deviceName))", bundle: bundle) }
    static var noComputerAudio: String { String(localized: "No computer audio", bundle: bundle) }
    static var recordComputerAudio: String { String(localized: "Record computer audio", bundle: bundle) }

    // MARK: - Settings

    static var general: String { String(localized: "General", bundle: bundle) }
    static var app: String { String(localized: "App", bundle: bundle) }
    static var integrations: String { String(localized: "Integrations", bundle: bundle) }
    static var ai: String { String(localized: "AI", bundle: bundle) }
    static var advanced: String { String(localized: "Advanced", bundle: bundle) }
    static var aiConnection: String { String(localized: "AI Connection", bundle: bundle) }
    static var diagnostics: String { String(localized: "Diagnostics", bundle: bundle) }
    static var notifications: String { String(localized: "Notifications", bundle: bundle) }
    static var calendar: String { String(localized: "Calendar", bundle: bundle) }
    static var cloudStorage: String { String(localized: "Cloud Storage", bundle: bundle) }
    static var aiSummary: String { String(localized: "AI Summary", bundle: bundle) }
    static var developerSettings: String { String(localized: "Developer Settings", bundle: bundle) }
    static var vault: String { String(localized: "Vault", bundle: bundle) }
    static var currentVault: String { String(localized: "Current Vault", bundle: bundle) }
    static var meetingDataAccess: String { String(localized: "Meeting Data Access", bundle: bundle) }
    static var vaultID: String { String(localized: "Vault ID", bundle: bundle) }
    static var copyCommand: String { String(localized: "Copy Command", bundle: bundle) }
    static var codexCLI: String { String(localized: "Codex CLI", bundle: bundle) }
    static var claudeCode: String { String(localized: "Claude Code", bundle: bundle) }
    static var meetingDataAccessHelperUnavailable: String { String(
        localized: "The meeting access helper is not available in this app build.",
        bundle: bundle
    ) }
    static var selectVaultForMeetingDataAccess: String { String(localized: "Select a vault before configuring meeting data access.", bundle: bundle) }
    static var meetingDataAccessFooter: String { String(
        localized: "Each command registers read-only access to only the selected vault. Run it again after switching vaults.",
        bundle: bundle
    ) }
    static func registrationCommand(_ name: String) -> String {
        String(format: String(localized: "%@ registration command", bundle: bundle), name)
    }

    static var currentVaultDescription: String { String(localized: "Choose the vault used for recordings and sync.", bundle: bundle) }
    static var noVaultSelected: String { String(localized: "No vault selected", bundle: bundle) }
    static var appearance: String { String(localized: "Appearance", bundle: bundle) }
    static var display: String { String(localized: "Display", bundle: bundle) }
    static var appLanguage: String { String(localized: "App Language", bundle: bundle) }
    static var appLanguageDescription: String { String(localized: "Set the display language for the app.", bundle: bundle) }
    static var followSystem: String { String(localized: "Follow System", bundle: bundle) }
    static var notificationSettingsDescription: String { String(
        localized: "Choose one or both conditions. Calendar notifications use events from enabled calendar sources.",
        bundle: bundle
    ) }
    static var transcriptionSettingsDescription: String { String(
        localized: "Choose which languages appear when starting transcription.",
        bundle: bundle
    ) }
    static var transcriptionMethod: String { String(localized: "Transcription Method", bundle: bundle) }
    static var enableRealtimeTranscription: String { String(localized: "Enable Real-time Transcription", bundle: bundle) }
    static var realtimeTranscriptionDescription: String { String(
        localized: "Show the transcript while recording. Accuracy may be lower than transcription after recording, and audio files are not saved.",
        bundle: bundle
    ) }
    static var batchTranscriptionDescription: String { String(
        localized: "Record audio first, then create a higher-accuracy transcript after recording stops.",
        bundle: bundle
    ) }
    static var retainBatchAudio: String { String(localized: "Keep Audio After Transcription", bundle: bundle) }
    static var retainBatchAudioDescription: String { String(
        localized: "Keep the protected audio in Dahlia after batch transcription succeeds.",
        bundle: bundle
    ) }
    static var transcriptTranslation: String { String(localized: "Transcript Translation", bundle: bundle) }
    static var transcriptTranslationDescription: String { String(
        localized: "Show translated transcript lines in the selected target language when available.",
        bundle: bundle
    ) }
    static var translationTargetLanguage: String { String(localized: "Target Language", bundle: bundle) }
    static var translationTargetLanguageDescription: String { String(
        localized: "Choose which language translated transcript lines should use.",
        bundle: bundle
    ) }
    static var translationDisabledForMatchingLanguage: String { String(
        localized: "Translation is automatically disabled when the target language matches the transcription language.",
        bundle: bundle
    ) }
    static var developerSettingsDescription: String { String(
        localized: "Override developer-managed credentials used by external service integrations.",
        bundle: bundle
    ) }
    static var googleOAuthClientIDOverride: String { String(localized: "Google OAuth Client ID", bundle: bundle) }
    static var googleOAuthClientIDOverrideDescription: String { String(
        localized: "Leave blank to use the bundled or environment-provided GOOGLE_CLIENT_ID.",
        bundle: bundle
    ) }
    static var googleOAuthClientSecretOverride: String { String(localized: "Google OAuth Client Secret", bundle: bundle) }
    static var googleOAuthClientSecretOverrideDescription: String { String(
        localized: "Optional. Stored in Keychain and used before GOOGLE_CLIENT_SECRET when set.",
        bundle: bundle
    ) }
    static var googleOAuthOverrideReconnectNotice: String { String(
        localized: "Reconnect Google services after changing OAuth credentials.",
        bundle: bundle
    ) }
    static var googleCalendar: String { String(localized: "Google Calendar", bundle: bundle) }
    static var macOSCalendar: String { String(localized: "macOS Calendar", bundle: bundle) }
    static var calendarSource: String { String(localized: "Calendar Source", bundle: bundle) }
    static var calendarSourceDescription: String { String(
        localized: "Choose which calendar service provides upcoming events.",
        bundle: bundle
    ) }
    static var calendarSources: String { String(localized: "Calendar Sources", bundle: bundle) }
    static var calendarSourcesDescription: String { String(
        localized: "Choose which calendar services provide upcoming events.",
        bundle: bundle
    ) }
    static var calendarEventsToInclude: String { String(localized: "Events to Include", bundle: bundle) }
    static var calendarEventsToIncludeDescription: String { String(
        localized: "Turn on the event types to show in Home, the menu bar, and calendar notifications.",
        bundle: bundle
    ) }
    static var calendarFilterAllDayEvents: String { String(localized: "All-day events", bundle: bundle) }
    static var calendarIncludeAllDayEventsDescription: String { String(
        localized: "Include events marked as all-day.",
        bundle: bundle
    ) }
    static var calendarFilterUserOnlyEvents: String { String(localized: "Events without other attendees", bundle: bundle) }
    static var calendarIncludeUserOnlyEventsDescription: String { String(
        localized: "Include events with no attendees other than you.",
        bundle: bundle
    ) }
    static var calendarFilterEventsWithoutMeetingURL: String { String(
        localized: "Events without a meeting URL",
        bundle: bundle
    ) }
    static var calendarIncludeEventsWithoutMeetingURLDescription: String { String(
        localized: "Include events that do not have a supported meeting URL.",
        bundle: bundle
    ) }
    static var calendarFilterDeclinedEvents: String { String(localized: "Declined events", bundle: bundle) }
    static var calendarIncludeDeclinedEventsDescription: String { String(
        localized: "Include events you declined.",
        bundle: bundle
    ) }
    static var calendarFilterOutOfOfficeEvents: String { String(localized: "OOO / OOTO events", bundle: bundle) }
    static var calendarIncludeOutOfOfficeEventsDescription: String { String(
        localized: "Include out-of-office events and events whose title includes OOO or OOTO.",
        bundle: bundle
    ) }
    static var calendarNoEventsMatchFiltersTitle: String { String(
        localized: "No events match your inclusion settings",
        bundle: bundle
    ) }
    static var calendarNoEventsMatchFiltersMessage: String { String(
        localized: "Upcoming events were found, but none match the event types you chose to include.",
        bundle: bundle
    ) }
    static var googleCalendarSourceDescription: String { String(
        localized: "Show events from Google Calendar.",
        bundle: bundle
    ) }
    static var macOSCalendarSourceDescription: String { String(
        localized: "Show events from the Calendar app on this Mac.",
        bundle: bundle
    ) }
    static var calendarScheduleTitle: String { String(localized: "Upcoming schedule", bundle: bundle) }
    static var showUpcomingSchedule: String { String(localized: "Show Upcoming Schedule", bundle: bundle) }
    static var calendarEventOriginTitle: String { String(localized: "From calendar event", bundle: bundle) }

    static func calendarEventOrigin(_ title: String) -> String {
        String(localized: "Calendar event: \(title)", bundle: bundle)
    }

    static var calendarScheduleDescription: String { String(
        localized: "Select a calendar event to prepare transcription.",
        bundle: bundle
    ) }
    static var googleDocs: String { String(localized: "Google Docs", bundle: bundle) }
    static var googleCalendarSettingsDescription: String { String(
        localized: "Connect a Google account and choose which calendars appear on Home.",
        bundle: bundle
    ) }
    static var macOSCalendarSettingsDescription: String { String(
        localized: "Use events from the Calendar app on this Mac.",
        bundle: bundle
    ) }
    static var googleDocsSettingsDescription: String { String(
        localized: "Connect a Google account to export summaries, including images, to Google Docs from the Share menu.",
        bundle: bundle
    ) }
    static var googleCalendarDisplayCalendars: String { String(localized: "Display Calendars", bundle: bundle) }
    static var googleCalendarDisplayCalendarsDescription: String { String(
        localized: "Only selected calendars are shown on Home.",
        bundle: bundle
    ) }
    static var macOSCalendarDisplayCalendarsDescription: String { googleCalendarDisplayCalendarsDescription }
    static var googleCalendarConnect: String { String(localized: "Connect", bundle: bundle) }
    static var googleCalendarDisconnect: String { String(localized: "Disconnect", bundle: bundle) }
    static var googleCalendarConnectDescription: String { String(
        localized: "Sign in with Google to load your upcoming schedule.",
        bundle: bundle
    ) }
    static var googleCalendarConnected: String { String(localized: "Connected", bundle: bundle) }
    static var googleCalendarNotConnected: String { String(localized: "No Google account connected", bundle: bundle) }
    static var googleDriveConnect: String { googleCalendarConnect }
    static var googleDriveDisconnect: String { googleCalendarDisconnect }
    static var googleDocsConnectDescription: String { String(
        localized: "Sign in with Google to export summaries to Google Docs.",
        bundle: bundle
    ) }
    static var googleDocsConnected: String { String(localized: "Google Docs connected", bundle: bundle) }
    static var googleDocsNotConnected: String { googleCalendarNotConnected }
    static var googleDriveExportDestination: String { String(localized: "Export Destination", bundle: bundle) }
    static var googleDriveExportFolder: String { String(localized: "Export Folder", bundle: bundle) }
    static var openInGoogleDrive: String { String(localized: "Open in Google Drive", bundle: bundle) }
    static var myDrive: String { String(localized: "My Drive", bundle: bundle) }
    static var googleDriveExportDestinationDescription: String { String(
        localized: "On first connection, Dahlia creates Meeting Notes directly under My Drive and exports Google Docs into it. The export destination is fixed to this folder.",
        bundle: bundle
    ) }
    static var googleDriveExportFolderNotConfigured: String { String(
        localized: "The Google Drive export folder has not been configured.",
        bundle: bundle
    ) }
    static var googleDriveExportFolderConfigurationFailed: String { String(
        localized: "Could not configure the Google Drive export folder.",
        bundle: bundle
    ) }
    static var openCloudStorageSettings: String { String(localized: "Open Cloud Storage Settings", bundle: bundle) }
    static var googleCalendarPrimaryCalendar: String { String(localized: "Primary calendar", bundle: bundle) }
    static var calendarPrimaryCalendar: String { googleCalendarPrimaryCalendar }
    static var googleCalendarNoCalendars: String { String(localized: "No calendars are available for this Google account.", bundle: bundle) }
    static var macOSCalendarNoCalendars: String { String(localized: "No calendars are available in macOS Calendar.", bundle: bundle) }
    static var calendarLoading: String { String(localized: "Loading calendars…", bundle: bundle) }
    static var googleCalendarLoading: String { String(localized: "Loading Google Calendar…", bundle: bundle) }
    static var macOSCalendarLoading: String { String(localized: "Loading macOS Calendar…", bundle: bundle) }
    static var googleCalendarRetry: String { String(localized: "Retry", bundle: bundle) }
    static var googleCalendarAllDay: String { String(localized: "All day", bundle: bundle) }
    static var calendarAllDay: String { googleCalendarAllDay }
    static var googleCalendarClientIDMissingTitle: String { String(localized: "Google Calendar is not configured", bundle: bundle) }
    static var googleCalendarClientIDMissingMessage: String { String(
        localized: "Set GOOGLE_CLIENT_ID before connecting Google Calendar.",
        bundle: bundle
    ) }
    static var googleCalendarSignInRequiredTitle: String { String(localized: "Connect Google Calendar", bundle: bundle) }
    static var googleCalendarSignInRequiredMessage: String { String(
        localized: "Connect Google Calendar from Settings to show your upcoming events on Home.",
        bundle: bundle
    ) }
    static var googleCalendarScheduleSignInRequiredMessage: String { String(
        localized: "Connect Google Calendar from Settings to show your upcoming events here.",
        bundle: bundle
    ) }
    static var googleCalendarSelectionRequiredTitle: String { String(localized: "Choose calendars to show", bundle: bundle) }
    static var calendarSelectionRequiredTitle: String { googleCalendarSelectionRequiredTitle }
    static var googleCalendarSelectionRequiredMessage: String { String(
        localized: "Select at least one calendar in Settings to show events on Home.",
        bundle: bundle
    ) }
    static var calendarSelectionRequiredMessage: String { googleCalendarSelectionRequiredMessage }
    static var googleCalendarScheduleSelectionRequiredMessage: String { String(
        localized: "Select at least one calendar in Settings to show events here.",
        bundle: bundle
    ) }
    static var calendarScheduleSelectionRequiredMessage: String { googleCalendarScheduleSelectionRequiredMessage }
    static var calendarNoSourcesEnabledTitle: String { String(localized: "No calendar sources enabled", bundle: bundle) }
    static var calendarNoSourcesEnabledMessage: String { String(
        localized: "Enable at least one calendar source in Settings to show upcoming events.",
        bundle: bundle
    ) }
    static var googleCalendarNoUpcomingEventsTitle: String { String(localized: "No upcoming events", bundle: bundle) }
    static var googleCalendarNoUpcomingEventsMessage: String { String(
        localized: "There are no events in the next 7 days for the selected calendars.",
        bundle: bundle
    ) }
    static var calendarNoUpcomingEventsMessage: String { googleCalendarNoUpcomingEventsMessage }
    static var googleCalendarLoadFailedTitle: String { String(localized: "Could not load Google Calendar", bundle: bundle) }
    static var macOSCalendarLoadFailedTitle: String { String(localized: "Could not load macOS Calendar", bundle: bundle) }
    static var macOSCalendarAccessRequiredTitle: String { String(localized: "Allow macOS Calendar access", bundle: bundle) }
    static var macOSCalendarAccessRequiredMessage: String { String(
        localized: "Allow Calendar access to show upcoming events from this Mac.",
        bundle: bundle
    ) }
    static var macOSCalendarAllowAccess: String { String(localized: "Allow Access", bundle: bundle) }
    static var macOSCalendarAccessDeniedTitle: String { String(localized: "macOS Calendar access is denied", bundle: bundle) }
    static var macOSCalendarAccessDeniedMessage: String { String(
        localized: "Allow Dahlia to access Calendars in System Settings > Privacy & Security > Calendars.",
        bundle: bundle
    ) }
    static var macOSCalendarAccessGranted: String { String(localized: "Calendar access granted", bundle: bundle) }
    static var macOSCalendarAccessNotGranted: String { String(localized: "Calendar access not granted", bundle: bundle) }
    static var macOSCalendarConnectDescription: String { String(
        localized: "Allow access to load your upcoming schedule from Calendar.",
        bundle: bundle
    ) }
    static var macOSCalendarConnected: String { String(localized: "macOS Calendar connected", bundle: bundle) }
    static var macOSCalendarUnexpectedError: String { String(localized: "Unexpected response from macOS Calendar", bundle: bundle) }
    static var macOSCalendarUntitledCalendar: String { String(localized: "Untitled calendar", bundle: bundle) }
    static var macOSCalendarUntitledEvent: String { String(localized: "Untitled event", bundle: bundle) }
    static var googleCalendarMissingPresentingWindow: String { String(
        localized: "No window is available to present Google sign-in.",
        bundle: bundle
    ) }
    static var googleCalendarNoPreviousSession: String { String(localized: "No previous Google Calendar session was found.", bundle: bundle) }
    static var googleAccountNoPreviousSession: String { String(localized: "No previous Google session was found.", bundle: bundle) }
    static var googleCalendarClientSecretMissingMessage: String { String(
        localized: "This Google OAuth client requires a client secret. Set GOOGLE_CLIENT_SECRET to the value from Google Cloud Console and relaunch Dahlia.",
        bundle: bundle
    ) }
    static var googleAccountClientIDMissingMessage: String { String(
        localized: "Set GOOGLE_CLIENT_ID before connecting Google services.",
        bundle: bundle
    ) }
    static var googleAccountClientSecretMissingMessage: String { googleCalendarClientSecretMissingMessage }
    static var googleCalendarKeychainConfigurationMessage: String { String(
        localized: "Google sign-in could not access Keychain. Rebuild the app with ./scripts/run-dev.sh so it is code signed with the required Keychain entitlements.",
        bundle: bundle
    ) }
    static var googleAccountKeychainConfigurationMessage: String { googleCalendarKeychainConfigurationMessage }
    static var googleCalendarUnknownAccount: String { String(localized: "Google Account", bundle: bundle) }
    static var googleAccountUnknown: String { googleCalendarUnknownAccount }
    static var googleAccountMissingPresentingWindow: String { googleCalendarMissingPresentingWindow }
    static var googleAccountUnexpectedResponse: String { String(localized: "Unexpected response from Google", bundle: bundle) }
    static func googleAccountHTTPError(_ code: Int, _ detail: String) -> String { String(
        localized: "Google HTTP \(code): \(detail)",
        bundle: bundle
    ) }
    static var googleAccountConnectedWithoutCalendar: String { String(
        localized: "Google account connected, but Calendar access has not been granted yet.",
        bundle: bundle
    ) }
    static var googleCalendarUntitledEvent: String { String(localized: "Untitled event", bundle: bundle) }
    static var googleCalendarUnexpectedResponse: String { String(localized: "Unexpected response from Google Calendar", bundle: bundle) }
    static func googleCalendarHTTPError(_ code: Int, _ detail: String) -> String { String(
        localized: "Google Calendar HTTP \(code): \(detail)",
        bundle: bundle
    ) }
    static func googleCalendarInvalidDate(_ value: String) -> String { String(
        localized: "Could not parse Google Calendar date: \(value)",
        bundle: bundle
    ) }
    static var googleDriveUnexpectedResponse: String { String(localized: "Unexpected response from Google Drive", bundle: bundle) }
    static func googleDriveHTTPError(_ code: Int, _ detail: String) -> String { String(
        localized: "Google Drive HTTP \(code): \(detail)",
        bundle: bundle
    ) }

    // MARK: - Vault Picker

    static var createNewVault: String { String(localized: "Create New Vault", bundle: bundle) }
    static var createNewVaultDescription: String { String(localized: "Create a new folder to use as a vault.", bundle: bundle) }
    static var addVault: String { String(localized: "Add Vault", bundle: bundle) }
    static var openFolderAsVault: String { String(localized: "Open Folder as Vault", bundle: bundle) }
    static var openFolderAsVaultDescription: String { String(localized: "Select an existing folder to use as a vault.", bundle: bundle) }
    static var removeVault: String { String(localized: "Remove Vault", bundle: bundle) }
    static var currentVaultRemoveDescription: String { String(
        localized: "Open a different vault before removing this one.",
        bundle: bundle
    ) }
    static func removeVaultConfirmation(_ name: String) -> String { String(localized: "Remove \(name)?", bundle: bundle) }
    static var removeVaultConfirmationDescription: String { String(
        localized: """
        Dahlia will remove this vault and its meeting history from the app. \
        Audio files managed outside the vault folder will also be deleted. \
        Files inside the vault folder are not changed.
        """,
        bundle: bundle
    ) }
    static var vaultDetails: String { String(localized: "Vault Details", bundle: bundle) }
    static var vaultName: String { String(localized: "Vault Name", bundle: bundle) }
    static var openVault: String { String(localized: "Open Vault", bundle: bundle) }
    static var openVaultDescription: String { String(localized: "Use this vault for recordings and sync.", bundle: bundle) }
    static var selectVaultDescription: String { String(localized: "Select a vault to view its details.", bundle: bundle) }
    static var noVaults: String { String(localized: "No Vaults", bundle: bundle) }
    static var noVaultsDescription: String { String(
        localized: "Add a folder to start recording and syncing meetings.",
        bundle: bundle
    ) }
    static var vaultOperationFailed: String { String(localized: "Vault Operation Failed", bundle: bundle) }
    static var vaultFolderSelectionFailed: String { String(localized: "Could not select the vault folder.", bundle: bundle) }
    static var vaultLoadFailed: String { String(localized: "Could not load vaults.", bundle: bundle) }
    static var vaultAddFailed: String { String(localized: "Could not add the vault.", bundle: bundle) }
    static var vaultRemoveFailed: String { String(localized: "Could not remove the vault.", bundle: bundle) }
    static var open: String { String(localized: "Open", bundle: bundle) }
    static var loadingLanguages: String { String(localized: "Loading supported languages...", bundle: bundle) }
    static var searchLanguages: String { String(localized: "Search languages...", bundle: bundle) }
    static var noMatchingLanguages: String { String(localized: "No matching languages", bundle: bundle) }
    static var allLanguagesShown: String { String(localized: "All languages shown", bundle: bundle) }
    static func languagesSelected(_ count: Int) -> String { String(localized: "\(count) languages selected", bundle: bundle) }
    static var showAll: String { String(localized: "Show all", bundle: bundle) }
    static var uncheckAll: String { String(localized: "Uncheck all", bundle: bundle) }
    static var displayLanguages: String { String(localized: "Display Languages", bundle: bundle) }
    static var displayLanguagesDescription: String { String(
        localized: "Only selected languages will appear in the language picker. All languages are shown if none are selected.",
        bundle: bundle
    ) }

    // MARK: - Settings (LLM)

    static var model: String { String(localized: "Model", bundle: bundle) }
    static var templates: String { String(localized: "Templates", bundle: bundle) }
    static var codexHelperNotBundled: String { String(
        localized: "The bundled Codex helper is unavailable. Run Dahlia with scripts/run-dev.sh or install a signed app build.",
        bundle: bundle
    ) }
    static func codexLaunchFailed(_ detail: String) -> String { String(
        localized: "Could not start Codex: \(detail)",
        bundle: bundle
    ) }
    static var codexNotLoggedIn: String { String(
        localized: "Codex is not signed in. Open AI Connection in Settings and sign in, then try again.",
        bundle: bundle
    ) }
    static func codexLoginFailed(_ detail: String) -> String { String(
        localized: "Codex sign-in failed: \(detail)",
        bundle: bundle
    ) }
    static var codexLoginFailedWithoutDetail: String { String(localized: "Codex sign-in failed.", bundle: bundle) }
    static var codexLoginPageCouldNotOpen: String { String(
        localized: "Could not open the Codex sign-in page.",
        bundle: bundle
    ) }
    static var codexProcessExited: String { String(localized: "Codex app-server exited unexpectedly.", bundle: bundle) }
    static func codexProcessExitedWithDetail(_ detail: String) -> String { String(
        localized: "Codex app-server exited unexpectedly: \(detail)",
        bundle: bundle
    ) }
    static func codexRequestTimedOut(_ operation: String) -> String { String(
        localized: "Codex did not respond in time (\(operation)). Try again.",
        bundle: bundle
    ) }
    static var codexInvalidResponse: String { String(localized: "Codex returned an invalid response.", bundle: bundle) }
    static var codexOutputBufferOverflow: String { String(
        localized: "Codex produced output faster than Dahlia could process it.",
        bundle: bundle
    ) }
    static func codexRequestFailed(_ detail: String) -> String { String(
        localized: "Codex request failed: \(detail)",
        bundle: bundle
    ) }
    static var codexTurnFailed: String { String(localized: "Codex could not complete the request.", bundle: bundle) }
    static var codexTurnInterrupted: String { String(localized: "Codex generation was interrupted.", bundle: bundle) }
    static var codexUnknownError: String { String(localized: "Unknown Codex app-server error.", bundle: bundle) }
    static var codexVersion: String { String(localized: "Codex Version", bundle: bundle) }
    static var account: String { String(localized: "Account", bundle: bundle) }
    static var aiAccountDescription: String { String(
        localized: "Choose the account used by Codex.",
        bundle: bundle
    ) }
    static var aiAccountSettingsDescription: String { String(
        localized: "AI summaries use the selected account and its available models.",
        bundle: bundle
    ) }
    static var chatGPTSubscription: String { String(localized: "ChatGPT Subscription", bundle: bundle) }
    static var databricks: String { String(localized: "Databricks", bundle: bundle) }
    static var codexAccount: String { String(localized: "Codex Account", bundle: bundle) }
    static var codexAppServer: String { String(localized: "Codex app-server", bundle: bundle) }
    static var codexAccountDescription: String { String(
        localized: "Dahlia stores a separate Codex sign-in for this app. Signing in opens your browser.",
        bundle: bundle
    ) }
    static var codexSignedIn: String { String(localized: "Signed in to Codex", bundle: bundle) }
    static func codexSignedInAs(_ account: String) -> String { String(
        localized: "Signed in to Codex as \(account)",
        bundle: bundle
    ) }
    static var codexNotSignedIn: String { String(localized: "Not signed in to Codex", bundle: bundle) }
    static var codexSignInNotRequired: String { String(localized: "Codex does not require sign-in", bundle: bundle) }
    static var signInWithChatGPT: String { String(localized: "Sign in with ChatGPT", bundle: bundle) }
    static var codexWaitingForBrowserSignIn: String { String(localized: "Waiting for browser sign-in…", bundle: bundle) }
    static var cancelSignIn: String { String(localized: "Cancel Sign-In", bundle: bundle) }
    static var signOut: String { String(localized: "Sign Out", bundle: bundle) }
    static var databricksProfile: String { String(localized: "Databricks CLI Profile", bundle: bundle) }
    static var databricksProfileDescription: String { String(
        localized: "Codex obtains the workspace and credentials from this Databricks CLI profile.",
        bundle: bundle
    ) }
    static var refreshDatabricksProfiles: String { String(localized: "Refresh Profiles", bundle: bundle) }
    static var noDatabricksProfiles: String { String(
        localized: "No Databricks CLI profiles found. Run databricks auth login in Terminal, then refresh.",
        bundle: bundle
    ) }
    static var databricksCLINotInstalled: String { String(
        localized: "Databricks CLI was not found. Install it and relaunch Dahlia.",
        bundle: bundle
    ) }
    static func databricksCLICommandFailed(_ detail: String) -> String { String(
        localized: "Databricks CLI authentication failed: \(detail)",
        bundle: bundle
    ) }
    static var databricksCLICommandFailedWithoutDetail: String { String(
        localized: "Databricks CLI authentication failed.",
        bundle: bundle
    ) }
    static var databricksCLIInvalidProfilesResponse: String { String(
        localized: "Databricks CLI returned an invalid profiles response.",
        bundle: bundle
    ) }
    static var databricksProfileRequired: String { String(localized: "Select a Databricks CLI profile.", bundle: bundle) }
    static var databricksWorkspaceURLInvalid: String { String(
        localized: "The selected Databricks CLI profile does not provide a valid HTTPS workspace URL.",
        bundle: bundle
    ) }
    static var databricksWorkspaceURL: String { String(localized: "Databricks Workspace URL", bundle: bundle) }
    static var databricksWorkspaceID: String { String(localized: "Databricks Workspace ID", bundle: bundle) }
    static var workspaceHostUnavailableFromProfile: String { String(
        localized: "Workspace URL unavailable from profile",
        bundle: bundle
    ) }
    static var workspaceIDUnavailableFromProfile: String { String(
        localized: "Workspace ID unavailable from profile",
        bundle: bundle
    ) }
    static var codexConfiguration: String { String(localized: "Codex Configuration", bundle: bundle) }
    static func codexConfigurationUpdateFailed(_ detail: String) -> String { String(
        localized: "Could not update the Codex configuration: \(detail)",
        bundle: bundle
    ) }
    static var databricksConfigured: String { String(localized: "Codex is configured for Databricks", bundle: bundle) }
    static var codexAccountConfigurationNotReady: String { String(
        localized: "The selected AI account is not ready. Open AI Connection in Settings and finish its configuration.",
        bundle: bundle
    ) }
    static var databricksCodexDescription: String { String(
        localized: "Dahlia writes the selected profile to its Codex configuration. Tokens remain managed by Databricks CLI.",
        bundle: bundle
    ) }
    static var codexNoModels: String { String(localized: "Codex returned no available models. Try again.", bundle: bundle) }
    static var codexModelDescription: String { String(
        localized: "Models are loaded from the bundled Codex app-server.",
        bundle: bundle
    ) }
    static var reasoningEffort: String { String(localized: "Reasoning Effort", bundle: bundle) }
    static var reasoningEffortDescription: String { String(
        localized: "Controls how much reasoning Codex uses for each summary.",
        bundle: bundle
    ) }
    static var reasoningEffortNone: String { String(localized: "None", bundle: bundle) }
    static var reasoningEffortMinimal: String { String(localized: "Minimal", bundle: bundle) }
    static var reasoningEffortLow: String { String(localized: "Low", bundle: bundle) }
    static var reasoningEffortMedium: String { String(localized: "Medium", bundle: bundle) }
    static var reasoningEffortHigh: String { String(localized: "High", bundle: bundle) }
    static var reasoningEffortExtraHigh: String { String(localized: "Extra High", bundle: bundle) }
    static var reasoningEffortMax: String { String(localized: "Max", bundle: bundle) }
    static var reasoningEffortUltra: String { String(localized: "Ultra", bundle: bundle) }
    static var codexSummaryModelFooter: String { String(
        localized: "The saved model is used when available; otherwise Codex's default model is selected.",
        bundle: bundle
    ) }
    static var llmErrorEmptyResponse: String { String(localized: "Empty response from server", bundle: bundle) }

    // MARK: - Summary

    static var generatingSummary: String { String(localized: "Generating summary...", bundle: bundle) }
    static var noSummaryYet: String { String(localized: "No summary has been generated yet.", bundle: bundle) }
    static var summaryImageUnavailable: String { String(localized: "Summary image unavailable", bundle: bundle) }
    static var summaryGenerated: String { String(localized: "Summary generated", bundle: bundle) }
    static var openSummary: String { String(localized: "Open Summary", bundle: bundle) }
    static var generateSummary: String { String(localized: "Generate Summary", bundle: bundle) }
    static var shareSummary: String { String(localized: "Share Summary", bundle: bundle) }
    static var exportToGoogleDocs: String { String(localized: "Export to Google Docs", bundle: bundle) }
    static var googleDocsExportFailed: String { String(localized: "Could not export the summary to Google Docs.", bundle: bundle) }
    static var copySummaryForGoogleDocs: String { String(localized: "Copy for Google Docs", bundle: bundle) }
    static var copySummaryForSlack: String { String(localized: "Copy for Slack", bundle: bundle) }
    static var summaryPrompt: String { String(localized: "Summary Prompt", bundle: bundle) }
    static var resetToDefault: String { String(localized: "Reset to Default", bundle: bundle) }
    static var summaryTemplate: String { String(localized: "Summary Template", bundle: bundle) }
    static var openInEditor: String { String(localized: "Open in Editor", bundle: bundle) }
    static var openTemplatesFolder: String { String(localized: "Open Templates Folder", bundle: bundle) }
    static var resetPresets: String { String(localized: "Reset Presets", bundle: bundle) }
    static var summaryTemplateDescription: String { String(localized: "Select a template from _custom_instructions/ in the vault.", bundle: bundle) }

    // MARK: - Error Messages (Audio)

    static var screenRecordingDenied: String { String(
        localized: "Screen recording access denied. Please allow it in System Settings > Privacy & Security > Screen Recording.",
        bundle: bundle
    ) }
    static var noDisplayFound: String { String(localized: "No available displays found", bundle: bundle) }
    static var invalidHardwareFormat: String { String(localized: "Invalid audio hardware format", bundle: bundle) }
    static var converterCreationFailed: String { String(localized: "Failed to create audio format converter", bundle: bundle) }
    static var microphoneDenied: String { String(
        localized: "Microphone access denied. Please allow it in System Settings > Privacy & Security > Microphone.",
        bundle: bundle
    ) }
    static var microphoneUnavailable: String { String(localized: "The selected microphone is unavailable", bundle: bundle) }
    static var noAudioSourceSelected: String { String(localized: "Select at least one audio source", bundle: bundle) }

    // MARK: - Debug

    static var debug: String { String(localized: "Debug", bundle: bundle) }
    static var audioRecognitionTest: String { String(localized: "Microphone & Speech Recognition Test", bundle: bundle) }
    static var audioRecognitionTestDescription: String { String(
        localized: "Test microphone input and speech recognition without creating a recording.",
        bundle: bundle
    ) }
    static var openAudioRecognitionTest: String { String(localized: "Open Test…", bundle: bundle) }
    static var applicationLogs: String { String(localized: "Application Logs", bundle: bundle) }
    static var openApplicationLogs: String { String(localized: "Open Logs…", bundle: bundle) }
    static var applicationLogsDescription: String { String(
        localized: "View Dahlia logs from the current app session. Private values remain redacted.",
        bundle: bundle
    ) }
    static var applicationLogsUnavailable: String { String(localized: "Logs Unavailable", bundle: bundle) }
    static var noApplicationLogs: String { String(localized: "No Logs", bundle: bundle) }
    static var noApplicationLogsDescription: String { String(
        localized: "Use Dahlia, then refresh to load new log entries.",
        bundle: bundle
    ) }
    static var searchApplicationLogs: String { String(localized: "Search logs…", bundle: bundle) }
    static var refreshApplicationLogs: String { String(localized: "Refresh Logs", bundle: bundle) }
    static var copyDisplayedLogs: String { String(localized: "Copy Displayed Logs", bundle: bundle) }
    static var systemMicrophoneMode: String { String(localized: "System Microphone Mode", bundle: bundle) }
    static var preferredMicrophoneMode: String { String(localized: "Selected Mode", bundle: bundle) }
    static var activeMicrophoneMode: String { String(localized: "Active Mode", bundle: bundle) }
    static var openMicrophoneModes: String { String(localized: "Open Microphone Modes…", bundle: bundle) }
    static var systemMicrophoneModeDescription: String { String(
        localized: """
        Dahlia uses the microphone mode selected in the macOS menu bar when the active audio route \
        supports it. Voice Isolation reduces speaker audio and surrounding noise.
        """,
        bundle: bundle
    ) }
    static var microphoneModeStandard: String { String(localized: "Standard", bundle: bundle) }
    static var microphoneModeWideSpectrum: String { String(localized: "Wide Spectrum", bundle: bundle) }
    static var microphoneModeVoiceIsolation: String { String(localized: "Voice Isolation", bundle: bundle) }
    static var microphoneModeUnknown: String { String(localized: "Unknown Mode", bundle: bundle) }
    static var microphoneCaptureLog: String { String(localized: "Microphone Capture Log", bundle: bundle) }
    static var microphoneCaptureLogDescription: String { String(
        localized: "Shows the startup sequence for the latest audio test or recording. Audio data is not stored.",
        bundle: bundle
    ) }
    static var microphoneCaptureRecording: String { String(localized: "App Recording", bundle: bundle) }
    static var microphoneCaptureAudioTest: String { String(localized: "Audio Test", bundle: bundle) }

    static func microphoneCaptureStage(_ stage: MicrophoneCaptureDiagnosticStage) -> String {
        String(localized: String.LocalizationValue(stage.rawValue), bundle: bundle)
    }

    static var startAudioRecognitionTest: String { String(localized: "Start Test", bundle: bundle) }
    static var stopAudioRecognitionTest: String { String(localized: "Stop Test", bundle: bundle) }
    static var stopRecordingBeforeAudioTest: String { String(
        localized: "Stop the current recording before starting an audio test.",
        bundle: bundle
    ) }
    static var audioRecognitionTestStatus: String { String(localized: "Test Status", bundle: bundle) }
    static var inputLevel: String { String(localized: "Input Level", bundle: bundle) }
    static var audioBuffers: String { String(localized: "Audio Buffers", bundle: bundle) }
    static func inputChannel(_ channel: Int) -> String { String(localized: "Input Channel \(channel)", bundle: bundle) }
    static var hardwareFormat: String { String(localized: "Hardware Format", bundle: bundle) }
    static var inputFormat: String { String(localized: "Input Format", bundle: bundle) }
    static var recognitionFormat: String { String(localized: "Recognition Format", bundle: bundle) }
    static var recognizedText: String { String(localized: "Recognized Text", bundle: bundle) }
    static var speakIntoSelectedMicrophone: String { String(localized: "Speak into the selected microphone.", bundle: bundle) }
    static var preparingAudioRecognitionTest: String { String(localized: "Preparing speech recognition…", bundle: bundle) }
    static var audioRecognitionTestListening: String { String(localized: "Listening", bundle: bundle) }
    static var audioRecognitionTestStopped: String { String(localized: "Stopped", bundle: bundle) }

    // MARK: - Error Messages (ViewModel)

    static var speechRecognitionUnavailable: String { String(localized: "Speech recognition is not available on this Mac", bundle: bundle) }
    static func speechPreparationFailed(_ error: String) -> String { String(
        localized: "Failed to prepare speech recognition: \(error)",
        bundle: bundle
    ) }
    static func languageChangeFailed(_ error: String) -> String { String(localized: "Failed to change language: \(error)", bundle: bundle) }
    static func actionItemAssigneeUpdateFailed(_ error: String) -> String { String(
        localized: "Could not update action item assignee: \(error)",
        bundle: bundle
    ) }
    static func actionItemDeleteFailed(_ error: String) -> String { String(localized: "Could not delete action item: \(error)", bundle: bundle) }
    static func actionItemUpdateFailed(_ error: String) -> String { String(localized: "Could not update action item: \(error)", bundle: bundle) }
    static var speechRecognitionNotReady: String { String(localized: "Speech recognition is not ready", bundle: bundle) }
    static var systemAudioCaptureStopped: String { String(localized: "System audio capture stopped", bundle: bundle) }
    static var microphoneCaptureStopped: String { String(localized: "Microphone capture stopped", bundle: bundle) }
    static var recording: String { String(localized: "Recording", bundle: bundle) }

    // MARK: - Sidebar Footer

    static var switchVault: String { String(localized: "Switch Vault", bundle: bundle) }
    static var manageVaults: String { String(localized: "Manage Vaults...", bundle: bundle) }
    static var manageProjects: String { String(localized: "Manage Projects...", bundle: bundle) }
    static var settings: String { String(localized: "Settings", bundle: bundle) }

    // MARK: - Menu Bar

    static var menuBarStartRecording: String { String(localized: "Start Recording", bundle: bundle) }
    static var menuBarStopRecording: String { String(localized: "Stop Recording", bundle: bundle) }
    static var menuBarOpenDahlia: String { String(localized: "Open Dahlia", bundle: bundle) }
    static var menuBarShowLiveSubtitles: String { String(localized: "Live Subtitles", bundle: bundle) }
    static var settingsMenuItem: String { String(localized: "Settings...", bundle: bundle) }
    static var menuBarQuitDahlia: String { String(localized: "Quit Dahlia", bundle: bundle) }
    static var menuBarCalendar: String { String(localized: "Menu Bar Calendar", bundle: bundle) }
    static var menuBarCalendarDescription: String { String(
        localized: "Choose which event details appear in the menu bar. Calendar selection and event filters above are shared.",
        bundle: bundle
    ) }
    static var menuBarCalendarDisplay: String { String(localized: "Show today's events", bundle: bundle) }
    static var menuBarCalendarDisplayDescription: String { String(
        localized: "Show ongoing and upcoming events in the menu bar menu.",
        bundle: bundle
    ) }
    static var menuBarCalendarEventTitle: String { String(localized: "Event title", bundle: bundle) }
    static var menuBarCalendarEventTitleDescription: String { String(
        localized: "Show the current or next event title in the menu bar.",
        bundle: bundle
    ) }
    static var menuBarCalendarCountdown: String { String(localized: "Time remaining", bundle: bundle) }
    static var menuBarCalendarCountdownDescription: String { String(
        localized: "Show the time until the event starts or ends.",
        bundle: bundle
    ) }
    static var menuBarNoMoreEventsToday: String { String(localized: "No more events today", bundle: bundle) }
    static var menuBarNoMoreEventsTodayDescription: String { String(
        localized: "There are no ongoing or upcoming events today.",
        bundle: bundle
    ) }
    static var menuBarOpenCalendarSettings: String { String(localized: "Open Calendar Settings", bundle: bundle) }
    static var menuBarInProgress: String { String(localized: "In progress", bundle: bundle) }
    static var menuBarStartingSoon: String { String(localized: "Starting soon", bundle: bundle) }
    static var menuBarEndingSoon: String { String(localized: "Ending soon", bundle: bundle) }

    static func menuBarOpenEventInDahlia(_ title: String) -> String {
        String(localized: "Open \(title) in Dahlia", bundle: bundle)
    }

    static func menuBarStartsIn(_ duration: String) -> String {
        String(localized: "Starts in \(duration)", bundle: bundle)
    }

    static func menuBarEndsIn(_ duration: String) -> String {
        String(localized: "Ends in \(duration)", bundle: bundle)
    }

    static func menuBarHoursAndMinutes(_ hours: Int, _ minutes: Int) -> String {
        String(localized: "\(hours) hr \(minutes) min", bundle: bundle)
    }

    static func menuBarHours(_ hours: Int) -> String {
        String(localized: "\(hours) hr", bundle: bundle)
    }

    static func menuBarMinutes(_ minutes: Int) -> String {
        String(localized: "\(minutes) min", bundle: bundle)
    }

    static var menuBarJoinMeetingWithRecording: String { String(localized: "Join Meeting (with recording)", bundle: bundle) }
    static var menuBarJoinMeeting: String { String(localized: "Join Meeting", bundle: bundle) }
    static var menuBarShowEventInCalendar: String { String(localized: "Show Event in Calendar", bundle: bundle) }
    static var calendarAttending: String { String(localized: "Attending", bundle: bundle) }

    // MARK: - Meeting Detection

    static var meetingNotifications: String { String(localized: "Meeting Notifications", bundle: bundle) }
    static var meetingNotificationsDescription: String { String(
        localized: "Notify me about meetings using macOS notifications.",
        bundle: bundle
    ) }
    static var notificationConditions: String { String(localized: "Notification Conditions", bundle: bundle) }
    static var notificationConditionsDescription: String { String(
        localized: "Choose when Dahlia sends a meeting notification.",
        bundle: bundle
    ) }
    static var microphoneActivityNotification: String { String(localized: "Meeting app microphone activity", bundle: bundle) }
    static var calendarEventNotification: String { String(localized: "One minute before calendar events", bundle: bundle) }
    static var calendarEventStartsInOneMinute: String { String(localized: "This event starts in one minute.", bundle: bundle) }
    static var joinAndStartRecording: String { String(localized: "Join and Start Recording", bundle: bundle) }
    static var startTranscription: String { String(localized: "Start Transcription", bundle: bundle) }
    static var meetingDetected: String { String(localized: "Meeting detected", bundle: bundle) }
    static func meetingDetectedSubtitle(_ appName: String) -> String { String(
        localized: "Meeting detected in \(appName)",
        bundle: bundle
    ) }
    static var noScreenshotsYet: String { String(localized: "No screenshots yet.", bundle: bundle) }

    // MARK: - Codex Chat

    static var chat: String { String(localized: "Chat", bundle: bundle) }
    static var newChat: String { String(localized: "New chat", bundle: bundle) }
    static var chatHistory: String { String(localized: "Chat history", bundle: bundle) }
    static var recentChats: String { String(localized: "Recent chats", bundle: bundle) }
    static var noRecentChats: String { String(localized: "No recent chats", bundle: bundle) }
    static var loadMore: String { String(localized: "Load more", bundle: bundle) }
    static var popOutChat: String { String(localized: "Open chat in a new window", bundle: bundle) }
    static var hideChat: String { String(localized: "Hide chat", bundle: bundle) }
    static var sendMessage: String { String(localized: "Send message", bundle: bundle) }
    static var stopGenerating: String { String(localized: "Stop generating", bundle: bundle) }
    static var messageCodex: String { String(localized: "Message Codex", bundle: bundle) }
    static var openAISettings: String { String(localized: "Open AI Connection Settings", bundle: bundle) }
    static var chatModelLoading: String { String(localized: "Loading models…", bundle: bundle) }
    static var chatWindowUnavailable: String { String(localized: "This chat is no longer available.", bundle: bundle) }
    static var resize: String { String(localized: "Resize", bundle: bundle) }
    static var chatShowAll: String { String(localized: "Show all chats", bundle: bundle) }
    static var copyChatMessage: String { String(localized: "Copy message", bundle: bundle) }
    static var selected: String { String(localized: "Selected", bundle: bundle) }
    static var responsePerformance: String { String(localized: "Response performance", bundle: bundle) }
}
