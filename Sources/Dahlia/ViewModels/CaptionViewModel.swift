// Recording, transcription, and persistence state remain under one established MainActor owner.
// swiftlint:disable file_length

import AppKit
import Combine
import CoreAudio
import CoreMedia
import DahliaRuntimeSupport
import GRDB
import os
@preconcurrency import ScreenCaptureKit
import Speech
import SwiftUI
import UniformTypeIdentifiers

private let captionViewModelLogger = Logger(subsystem: "com.dahlia", category: "CaptionViewModel")

struct SummaryGenerationRunnerInput {
    let promptContext: SummaryPromptContext
    let transcriptText: String
    let noteText: String?
    let screenshots: [MeetingScreenshotRecord]
    let recordingSessions: [RecordingSessionTimeline]
    let generationSettings: SummaryGenerationSettings
}

typealias SummaryGenerationRunner = @MainActor (SummaryGenerationRunnerInput) async throws -> SummaryService.GeneratedSummary
typealias SummaryJobSleeper = @Sendable (Duration) async throws -> Void
typealias SummaryGoogleDocsExporter = @MainActor (SummaryDocument, SummaryRenderContext, String) async throws -> String
typealias SummaryDocumentLoader = @MainActor (UUID, DatabaseQueue) async throws -> SummaryDocument?

private enum SummaryGoogleDocsExportError: Error {
    case summaryChanged
}

/// 録音中のナビゲーション時に保持する録音コンテキスト。
private struct RecordingContext {
    let meetingId: UUID?
    let store: TranscriptStore
    let projectURL: URL?
    let projectId: UUID?
    let projectName: String?
    let vaultURL: URL?
    let dbQueue: DatabaseQueue?
    let batchTranscriptionState: BatchTranscriptionState?
}

private struct PersistenceStartRequest {
    let dbQueue: DatabaseQueue
    let vaultId: UUID
    let projectId: UUID?
    let existingMeetingId: UUID?
    let recordingStartTime: Date
    let recordingSessionId: UUID
    let transcriptionMode: TranscriptionMode
    let persistencePolicy: TranscriptPersistencePolicy
    let retainAudioAfterBatch: Bool
    let draftMeeting: DraftMeeting?
    let initialMeetingName: String
}

private struct RecordingStartRollbackState {
    let segments: [TranscriptSegment]
    let recordingSessions: [RecordingSessionTimeline]
    let recordingStartTime: Date?
    let preservedDraftContext: PreservedDraftContext?
}

private struct PreservedDraftContext {
    let meeting: DraftMeeting
    let vaultURL: URL?
    let dbQueue: DatabaseQueue?
}

private struct RecordingStopContext {
    let configurationTasks: [Task<Void, Never>]
    let automaticScreenshotStopTask: Task<Void, Never>
    let store: TranscriptStore
    let meetingId: UUID?
    let projectName: String?
    let vaultURL: URL?
    let dbQueue: DatabaseQueue?
    let recordingStart: Date
    let transcriptionMode: TranscriptionMode
    let telemetry: RecordingTelemetryContext?
    let recordingSessionId: UUID?
}

struct RecordingTelemetryContext {
    let mode: UsageTelemetryEvent.TranscriptionModeValue
    let audioSources: UsageTelemetryEvent.AudioSources
    let meetingScope: UsageTelemetryEvent.MeetingScope
    let trigger: UsageTelemetryEvent.RecordingTrigger?
    var recordingFailureStage: UsageTelemetryEvent.RecordingFailureStage?
    var transcriptionFailureStage: UsageTelemetryEvent.TranscriptionFailureStage?

    func terminalEvents(recordingDuration: TimeInterval?) -> [UsageTelemetryEvent] {
        let recordingLifecycle: UsageTelemetryEvent.Lifecycle<UsageTelemetryEvent.RecordingFailureStage> =
            recordingFailureStage.map { .failed($0) } ?? .completed
        var events: [UsageTelemetryEvent] = [
            .recording(
                recordingLifecycle,
                mode: mode,
                sources: audioSources,
                meetingScope: meetingScope,
                duration: recordingLifecycle == .completed ? recordingDuration : nil,
                trigger: trigger
            ),
        ]
        if mode == .realtime {
            let transcriptionLifecycle: UsageTelemetryEvent
                .Lifecycle<UsageTelemetryEvent.TranscriptionFailureStage> =
                transcriptionFailureStage.map { .failed($0) } ?? .completed
            events.append(.transcription(transcriptionLifecycle, mode: mode))
        }
        return events
    }
}

private struct RecordingControllerStartRequest {
    let dbQueue: DatabaseQueue
    let meetingId: UUID?
    let sessionId: UUID
    let startedAt: Date
    let plan: TranscriptionSessionPlan
    let transcriptionLocale: Locale
    let liveRecognitionLocale: Locale
    let batchSampleRate: Double?
}

private enum RecordingLifecycle: Equatable {
    case idle
    case starting(UUID)
    case recording(UUID)
    case stopping(UUID)
}

private struct RecordingPipelineFailure: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

/// 音声キャプチャ → Speech フレームワーク文字起こし → UI 更新を統括するビューモデル。
@MainActor
// swiftlint:disable:next type_body_length
final class CaptionViewModel: ObservableObject {

    // MARK: - Published State

    @Published var store = TranscriptStore() {
        didSet {
            bindStoreSegments()
        }
    }

    let liveCaptionStore = LiveCaptionStore()
    var finalizedLiveTranscriptHandler: (@MainActor (String, Bool) -> Void)?
    var chatLiveModeFailureHandler: (@MainActor () -> Void)?

    @Published var isListening = false
    @Published var isFinalizingRecording = false {
        didSet { updateCanBeginRecording() }
    }

    @Published private(set) var canBeginRecording = true
    @Published private(set) var isRecordingStartPending = false {
        didSet { updateCanBeginRecording() }
    }

    @Published var analyzerReady = false
    @Published var isPreparingAnalyzer = false
    @Published private(set) var activeTranscriptionMode: TranscriptionMode?
    @Published private(set) var batchTranscriptionState: BatchTranscriptionState?
    @Published var batchTranscriptionRecoveryAlert: BatchTranscriptionRecoveryAlert?
    @Published private(set) var offscreenBatchTranscriptionChangeToken: UInt64 = 0
    @Published private(set) var retranscribableBatchSessionIds: [UUID] = []
    @Published private(set) var failedPersistenceMeetingId: UUID?
    @Published var pendingBatchTranscriptionConfirmation: BatchTranscriptionConfirmation?
    @Published var errorMessage: String?
    @Published var availableMicrophones: [MicrophoneDevice] = []
    @Published private(set) var defaultInputDeviceID: AudioDeviceID? {
        didSet { updateCanBeginRecording() }
    }

    @Published private var hasResolvedDefaultInputDevice = false {
        didSet { updateCanBeginRecording() }
    }

    @Published var microphoneSelection: MicrophoneSelection = .systemDefault {
        didSet { updateCanBeginRecording() }
    }

    @Published var isSystemAudioEnabled = true {
        didSet { updateCanBeginRecording() }
    }

    @Published private(set) var activeControllerSources: Set<RecordingAudioSource> = []
    @Published private(set) var appliedLiveRecognitionLocaleIdentifier: String?
    let recordingAudioLevelStore = RecordingAudioLevelStore()

    @Published private(set) var transcriptionLocale: String = AppSettings.shared.transcriptionLocale
    @Published var liveSubtitleLocale: String = AppSettings.shared.liveSubtitleLocale {
        didSet {
            guard liveSubtitleLocale != oldValue else { return }
            updateFilteredLocales()
            guard !isSynchronizingLiveSubtitleLocale else { return }
            applyLiveSubtitleLocaleChange(from: oldValue, to: liveSubtitleLocale)
        }
    }

    @Published var supportedLocales: [Locale] = []
    @Published var filteredLocales: [Locale] = []

    // MARK: - Meeting State

    var currentMeetingId: UUID?
    var currentProjectURL: URL?
    var currentProjectId: UUID?
    var currentProjectName: String?
    var currentVaultURL: URL?
    @Published private(set) var draftMeeting: DraftMeeting?
    @Published private(set) var pendingDraftMaterializations: [DraftMeetingMaterialization] = []

    // MARK: - Summary State

    @Published private(set) var summaryGenerationJobs: [SummaryGenerationJob] = []
    @Published var summaryGeneratingMeetingIDs: Set<UUID> = []
    private var pendingBatchSummaryRequestsBySessionId: [UUID: PendingBatchSummaryRequest] = [:]
    private var batchSummaryContextsBySessionId: [UUID: BatchSummaryContext] = [:]
    @Published private var summaryErrorsByMeetingId: [UUID: String] = [:]
    @Published private var googleDocsExportErrorsByMeetingId: [UUID: String] = [:]
    var isSummaryGenerating: Bool {
        currentMeetingId.map(isSummaryGenerating(meetingId:)) ?? false
    }

    var summaryError: String? {
        currentMeetingId.flatMap { summaryErrorsByMeetingId[$0] }
    }

    var googleDocsExportError: String? {
        currentMeetingId.flatMap { googleDocsExportErrorsByMeetingId[$0] }
    }

    private var isExportingCurrentSummaryToGoogleDocs = false
    private var isGoogleDocsExportBusy = false
    private var googleDocsExportWaiters: [CheckedContinuation<Void, Never>] = []
    @Published var lastSummaryURL: URL?
    @Published var currentSummaryGoogleFileId: String?
    @Published var currentSummaryDocument: SummaryDocument?

    var canRetranscribeBatchAudio: Bool {
        guard !retranscribableBatchSessionIds.isEmpty, !isListening else { return false }
        return switch batchTranscriptionState {
        case nil, .failed, .retranscriptionFailed, .interrupted:
            true
        default:
            false
        }
    }

    var canStartOrResumeBatchTranscription: Bool {
        guard !isListening else { return false }
        return switch batchTranscriptionState {
        case .awaitingConfirmation:
            true
        case .failed, .retranscriptionFailed, .interrupted:
            !retranscribableBatchSessionIds.isEmpty
        default:
            false
        }
    }

    var batchTranscriptionActionTitle: String {
        switch batchTranscriptionState {
        case .awaitingConfirmation:
            L10n.reviewBatchTranscription
        case .interrupted:
            L10n.resumeBatchTranscription
        case .failed, .retranscriptionFailed:
            L10n.retryBatchTranscription
        default:
            L10n.transcribe
        }
    }

    var batchTranscriptionFailureMessage: String? {
        switch batchTranscriptionState {
        case let .failed(_, message), let .retranscriptionFailed(_, message):
            message
        default:
            nil
        }
    }

    var isBatchRetranscriptionFailure: Bool {
        if case .retranscriptionFailed = batchTranscriptionState { true } else { false }
    }

    /// Summary タブへの切り替えをリクエストするフラグ。
    @Published var requestShowSummaryTab = false

    // MARK: - Note State

    @Published var noteText = ""
    private var hasNote = false
    private var currentNoteCreatedAt: Date?
    private var noteAutoSaveCancellable: AnyCancellable?
    private var lastSavedNoteText: String?

    // MARK: - Screenshot State

    let screenshotStore = ScreenshotStore()
    let conversationMetricsStore = MeetingConversationMetricsStore()

    @Published private(set) var isDeletingScreenshots = false {
        didSet {
            guard oldValue, !isDeletingScreenshots else { return }
            generatePendingBatchSummariesIfReady()
        }
    }

    /// キャプチャ対象として選択可能なウィンドウ一覧。
    @Published var availableWindows: [ScreenshotWindowOption] = []
    /// スクリーンショット取得対象。未設定の場合はキャプチャしない。
    @Published var screenshotCaptureSource: ScreenshotCaptureSource = .none {
        didSet {
            guard screenshotCaptureSource != oldValue else { return }
            syncAutomaticScreenshotCaptureState()
        }
    }

    @Published private(set) var currentMeetingHasTranscriptSegments = false

    var hasCurrentMeetingSummary: Bool {
        guard let currentSummaryDocument else { return false }
        return !currentSummaryDocument.sections.isEmpty || !currentSummaryDocument.actionItems.isEmpty
    }

    var canShareCurrentSummary: Bool {
        guard let currentSummaryDocument else { return false }
        return currentSummaryDocument.title.nilIfBlank != nil
            || !currentSummaryDocument.sections.isEmpty
            || !currentSummaryDocument.actionItems.isEmpty
    }

    var hasDraftMeeting: Bool {
        draftMeeting != nil
    }

    var draftMeetingTitle: String {
        let trimmed = draftMeeting?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? L10n.newMeeting : trimmed
    }

    var currentSummaryGoogleFileURL: URL? {
        guard let fileId = currentSummaryGoogleFileId?.nilIfBlank else { return nil }
        return URL(string: "https://docs.google.com/document/d/\(fileId)/edit")
    }

    func copyCurrentSummary(for destination: SummaryShareRenderer.Destination) {
        guard let currentSummaryDocument, canShareCurrentSummary else { return }

        let content = SummaryShareRenderer.render(
            document: currentSummaryDocument,
            actionItemsHeading: L10n.actionItems,
            for: destination,
            screenshots: screenshotStore.records
        )
        guard content.markdown.nilIfBlank != nil else { return }
        SummaryPasteboardWriter.write(content)
    }

    @discardableResult
    func exportCurrentSummaryToGoogleDocs() async -> Bool {
        guard !isExportingCurrentSummaryToGoogleDocs,
              let document = currentSummaryDocument,
              let meetingId = currentMeetingId,
              canShareCurrentSummary else { return false }

        isExportingCurrentSummaryToGoogleDocs = true
        googleDocsExportErrorsByMeetingId.removeValue(forKey: meetingId)
        defer { isExportingCurrentSummaryToGoogleDocs = false }
        usageTelemetryReporter(.export(.started, destination: .googleDocs, trigger: .manual))

        let context = SummaryRenderContext(
            meetingId: meetingId,
            createdAt: store.timeBase,
            screenshots: screenshotStore.records
        )
        let fileName = lastSummaryURL?.lastPathComponent
            ?? "\(document.title.nilIfBlank ?? L10n.summary).rtf"
        let dbQueue = currentDbQueue

        do {
            let expectedDocument = try document.databaseJSONString()
            let fileId = try await exportSummaryToGoogleDocs(
                document: document,
                context: context,
                fileName: fileName
            )
            try persistGoogleDocsFileId(
                fileId,
                meetingId: meetingId,
                expectedDocument: expectedDocument,
                dbQueue: dbQueue
            )
            if let url = URL(string: "https://docs.google.com/document/d/\(fileId)/edit") {
                NSWorkspace.shared.open(url)
            }
            usageTelemetryReporter(.export(.completed, destination: .googleDocs, trigger: .manual))
            return true
        } catch {
            let message = GoogleAuthErrorFormatter.message(
                for: error,
                defaultMessage: L10n.googleDocsExportFailed
            )
            googleDocsExportErrorsByMeetingId[meetingId] = message
            ErrorReportingService.captureSanitized(.googleDocsExport)
            usageTelemetryReporter(.export(.failed(.export), destination: .googleDocs, trigger: .manual))
            return false
        }
    }

    /// 録音中でなく、文字起こしを表示中の場合 true。
    var isViewingHistory: Bool {
        !isListening && currentMeetingId != nil
    }

    var selectedMicrophoneID: AudioDeviceID? {
        microphoneSelection.resolvedDeviceID(defaultDeviceID: defaultInputDeviceID)
    }

    var microphoneCaptureDeviceID: AudioDeviceID? {
        guard case let .device(deviceID) = microphoneSelection else { return nil }
        return deviceID
    }

    var systemDefaultMicrophoneTitle: String {
        Self.systemDefaultMicrophoneTitle(
            microphones: availableMicrophones,
            defaultDeviceID: defaultInputDeviceID
        )
    }

    static func systemDefaultMicrophoneTitle(
        microphones: [MicrophoneDevice],
        defaultDeviceID: AudioDeviceID?
    ) -> String {
        guard let defaultDeviceID,
              let deviceName = microphones.first(where: { $0.id == defaultDeviceID })?.name else {
            return L10n.sameAsSystem
        }
        return L10n.sameAsSystem(deviceName)
    }

    /// 初回の HAL 問い合わせ中は system default を楽観的に有効とみなし、起動操作を妨げない。
    var isMicEnabled: Bool {
        switch microphoneSelection {
        case .systemDefault:
            !hasResolvedDefaultInputDevice || defaultInputDeviceID != nil
        case .device:
            true
        case .none:
            false
        }
    }

    var isBatchRecording: Bool {
        isListening && activeTranscriptionMode == .batch
    }

    var liveRecognitionLocaleIdentifier: String {
        if let appliedLiveRecognitionLocaleIdentifier {
            return appliedLiveRecognitionLocaleIdentifier
        }
        return (activeTranscriptionMode ?? AppSettings.shared.transcriptionMode) == .realtime
            ? transcriptionLocale
            : liveSubtitleLocale
    }

    var showsTranscriptTranslations: Bool {
        let settings = AppSettings.shared
        let sourceLocaleIdentifier = isListening
            ? liveRecognitionLocaleIdentifier
            : settings.transcriptionLocale
        return settings.liveSubtitleTranslationEnabled && TranscriptTranslationLanguage.shouldTranslate(
            transcriptionLocaleIdentifier: sourceLocaleIdentifier,
            targetLanguageIdentifier: settings.liveSubtitleTranslationTargetLanguage
        )
    }

    func setChatLiveModeEnabled(_ isEnabled: Bool) {
        guard isChatLiveModeEnabled != isEnabled else { return }
        isChatLiveModeEnabled = isEnabled

        guard var plan = activeTranscriptionPlan,
              let recordingSessionId = activeRecordingSessionId else { return }
        plan.liveChatEnabled = isEnabled
        activeTranscriptionPlan = plan

        guard case let .recording(activeSessionID) = recordingLifecycle,
              activeSessionID == recordingSessionId else { return }
        enqueueRecordingConfiguration { [weak self] _ in
            guard let self,
                  self.activeTranscriptionPlan?.liveChatEnabled == isEnabled else { return }
            do {
                let locale = self.appliedLiveRecognitionLocale()
                let snapshot = try await self.recordingSessionController.setLiveChatEnabled(
                    isEnabled,
                    translateSegment: self.translationHandler(for: locale)
                )
                self.applyControllerSnapshot(snapshot)
            } catch {
                guard self.activeTranscriptionPlan?.liveChatEnabled == isEnabled else { return }
                self.errorMessage = error.localizedDescription
                self.isChatLiveModeEnabled = false
                self.activeTranscriptionPlan?.liveChatEnabled = false
                self.chatLiveModeFailureHandler?()
            }
        }
    }

    /// 少なくとも 1 つの音声ソースが有効か。
    var hasEnabledAudioSource: Bool { isMicEnabled || isSystemAudioEnabled }

    var canSwitchVault: Bool {
        !isRecordingStartPending
            && recordingLifecycle == .idle
            && !isFinalizingRecording
    }

    private var enabledRecordingAudioSources: Set<RecordingAudioSource> {
        var sources: Set<RecordingAudioSource> = []
        if isMicEnabled {
            sources.insert(.microphone)
        }
        if isSystemAudioEnabled {
            sources.insert(.system)
        }
        return sources
    }

    // MARK: - Recording Context (録音中のナビゲーション時に保持)

    /// 録音中に別トランスクリプトへナビゲーションした際の録音コンテキスト。
    private var recordingContext: RecordingContext?
    private var finalizingMeetingId: UUID?

    /// 録音対象の文字起こし ID。
    /// recordingContext 初期化前（録音開始〜別トランスクリプトへ遷移前）は currentMeetingId で補う。
    var recordingMeetingId: UUID? {
        recordingContext?.meetingId
            ?? finalizingMeetingId
            ?? ((isListening || isFinalizingRecording) ? currentMeetingId : nil)
    }

    var isCurrentMeetingConversationAnalysisPending: Bool {
        Self.conversationAnalysisIsPending(
            currentMeetingId: currentMeetingId,
            recordingMeetingId: recordingMeetingId,
            isListening: isListening,
            isFinalizingRecording: isFinalizingRecording,
            isBatchTranscriptionPending: batchTranscriptionState?.blocksSummaryGeneration == true,
            failedPersistenceMeetingId: failedPersistenceMeetingId
        )
    }

    nonisolated static func conversationAnalysisIsPending(
        currentMeetingId: UUID?,
        recordingMeetingId: UUID?,
        isListening: Bool,
        isFinalizingRecording: Bool,
        isBatchTranscriptionPending: Bool,
        failedPersistenceMeetingId: UUID?
    ) -> Bool {
        if isBatchTranscriptionPending {
            return true
        }
        if let currentMeetingId, failedPersistenceMeetingId == currentMeetingId {
            return true
        }
        guard let currentMeetingId,
              isListening || isFinalizingRecording else { return false }
        return recordingMeetingId == currentMeetingId
    }

    /// 録音中かつ録音対象とは別のトランスクリプトを閲覧中。
    var isViewingOtherWhileRecording: Bool {
        isListening && recordingContext != nil
    }

    var activeMeetingIdForSessionControls: UUID? {
        recordingContext?.meetingId ?? currentMeetingId
    }

    var activeTranscriptStore: TranscriptStore {
        recordingContext?.store ?? store
    }

    func isRecordingAudioSourceActive(_ source: RecordingAudioSource) -> Bool {
        activeControllerSources.contains(source)
    }

    // MARK: - Private

    private var currentDbQueue: DatabaseQueue?
    private var persistenceService: MeetingPersistenceService?
    private var failedPersistenceService: MeetingPersistenceService?
    private var failedTranscriptionEventPipeline: TranscriptionEventPipeline?
    private var summaryPersistenceRecoveryTask: Task<String?, Never>?
    private var transcriptionEventPipeline: TranscriptionEventPipeline?
    private var liveCaptionEventRelay: LiveCaptionEventRelay?
    private var liveTranscriptRelay: FinalizedLiveTranscriptRelay?
    private var isChatLiveModeEnabled = false
    private var searchIndexer: SearchIndexer?
    private var batchTranscriptionCoordinator: BatchTranscriptionCoordinator?
    private var batchTranscriptionRecoveryTask: Task<Void, Never>?
    private var activeBatchTelemetrySessionIDs: Set<UUID> = []
    private var activeRecordingTelemetryContext: RecordingTelemetryContext?
    private var onBatchTranscriptionRecoveryCompleted: (@MainActor @Sendable () async -> Void)?
    private var recordingStopTask: Task<Void, Never>?
    private var isTerminationRequested = false
    private let recordingSessionController = RecordingSessionController()
    private var activeTranscriptionPlan: TranscriptionSessionPlan?
    private var activeRecordingSessionId: UUID?
    private var recordingLifecycle: RecordingLifecycle = .idle {
        didSet { updateCanBeginRecording() }
    }

    struct RecordingStartReservation: Equatable {
        fileprivate let id: UUID
    }

    private var activeRecordingStartReservation: RecordingStartReservation?

    var isRecordingLifecycleBusy: Bool {
        recordingLifecycle != .idle || isRecordingStartPending || isFinalizingRecording
    }

    private var recordingConfigurationTasks: [Int: Task<Void, Never>] = [:]
    private var nextRecordingConfigurationID = 0
    private var pendingRealtimeRecognitionFailure: (source: RecordingAudioSource?, message: String)?
    private var pendingLiveSubtitleWarning: String?
    private var startingMicrophoneSelection: MicrophoneSelection?
    private var startingSystemAudioEnabled: Bool?
    private var startingTranscriptionLocaleIdentifier: String?
    private var startingLiveSubtitleLocaleIdentifier: String?
    private var settingsCancellable: AnyCancellable?
    private var storeSegmentsCancellable: AnyCancellable?
    private var transcriptionLocaleCancellable: AnyCancellable?
    private var liveSubtitleLocaleCancellable: AnyCancellable?
    private var liveSubtitleSettingsCancellable: AnyCancellable?
    private var automaticScreenshotSettingsCancellables: Set<AnyCancellable> = []
    private var meetingLoadTask: Task<Void, Never>?
    private var meetingLoadGeneration: UInt64 = 0
    private var summaryReloadTask: Task<Void, Never>?
    private var summaryProjectionGeneration: UInt64 = 0
    private var isSynchronizingLiveSubtitleLocale = false
    private let audioHardwareQueryService: AudioHardwareQueryService
    private let transcriptTranslationService = TranscriptTranslationService()
    private let automaticScreenshotCaptureControl: AutomaticScreenshotCaptureControl
    private let summaryGenerationRunner: SummaryGenerationRunner
    private let summaryJobSleeper: SummaryJobSleeper
    private let googleDocsSummaryExporter: SummaryGoogleDocsExporter
    private let summaryDocumentLoader: SummaryDocumentLoader
    private let usageTelemetryReporter: UsageTelemetryReporter

    private func updateCanBeginRecording() {
        let updatedValue = recordingLifecycle == .idle
            && !isRecordingStartPending
            && !isFinalizingRecording
            && hasEnabledAudioSource
        guard canBeginRecording != updatedValue else { return }
        canBeginRecording = updatedValue
    }

    private var activeDbQueueForSessionControls: DatabaseQueue? {
        recordingContext?.dbQueue ?? currentDbQueue
    }

    init(
        audioHardwareQueryService: AudioHardwareQueryService = .shared,
        automaticScreenshotCapture: any AutomaticScreenshotCapturing = AutomaticScreenshotCaptureService(),
        summaryGenerationRunner: @escaping SummaryGenerationRunner = { input in
            try await SummaryService.generateSummary(
                promptContext: input.promptContext,
                transcriptText: input.transcriptText,
                noteText: input.noteText,
                screenshots: input.screenshots,
                recordingSessions: input.recordingSessions,
                generationSettings: input.generationSettings
            )
        },
        summaryJobSleeper: @escaping SummaryJobSleeper = { try await Task.sleep(for: $0) },
        googleDocsSummaryExporter: @escaping SummaryGoogleDocsExporter = { document, context, fileName in
            try await GoogleDocsSummaryExportService.exportSummary(
                document: document,
                context: context,
                fileName: fileName
            )
        },
        summaryDocumentLoader: @escaping SummaryDocumentLoader = { meetingId, dbQueue in
            try await Task.detached(priority: .userInitiated) {
                try dbQueue.read { db in
                    try SummaryRecord.fetchOne(db, key: meetingId)?.loadDocument()
                }
            }.value
        },
        usageTelemetryReporter: @escaping UsageTelemetryReporter = { event in
            UsageTelemetryService.shared.record(event)
        }
    ) {
        self.audioHardwareQueryService = audioHardwareQueryService
        automaticScreenshotCaptureControl = AutomaticScreenshotCaptureControl(
            capture: automaticScreenshotCapture
        )
        self.summaryGenerationRunner = summaryGenerationRunner
        self.summaryJobSleeper = summaryJobSleeper
        self.googleDocsSummaryExporter = googleDocsSummaryExporter
        self.summaryDocumentLoader = summaryDocumentLoader
        self.usageTelemetryReporter = usageTelemetryReporter
        bindStoreSegments()
        Task { [weak self] in
            await self?.refreshAvailableMicrophones()
        }

        // AppSettings の表示言語設定変更を監視
        settingsCancellable = UserDefaults.standard
            .publisher(for: \.enabledLocaleIdentifiers)
            .merge(with: UserDefaults.standard.publisher(for: \.transcriptionLanguageScope))
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateFilteredLocales()
            }

        transcriptionLocaleCancellable = UserDefaults.standard
            .publisher(for: \.transcriptionLocale)
            .compactMap(\.self)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] localeIdentifier in
                guard let self, self.transcriptionLocale != localeIdentifier else { return }
                let previousLocaleIdentifier = self.transcriptionLocale
                self.transcriptionLocale = localeIdentifier
                self.updateFilteredLocales()
                self.applyTranscriptionLocaleChange(from: previousLocaleIdentifier, to: localeIdentifier)
            }

        liveSubtitleLocaleCancellable = UserDefaults.standard
            .publisher(for: \.liveSubtitleLocale)
            .compactMap(\.self)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] localeIdentifier in
                guard let self, self.liveSubtitleLocale != localeIdentifier else { return }
                self.liveSubtitleLocale = localeIdentifier
            }

        liveSubtitleSettingsCancellable = UserDefaults.standard
            .publisher(for: \.liveSubtitleOverlayEnabled)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] isEnabled in
                self?.handleLiveSubtitleSettingChange(isEnabled: isEnabled)
            }

        UserDefaults.standard
            .publisher(for: \.automaticScreenshotEnabled)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncAutomaticScreenshotCaptureState()
            }
            .store(in: &automaticScreenshotSettingsCancellables)

        UserDefaults.standard
            .publisher(for: \.automaticScreenshotIntervalSeconds)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateAutomaticScreenshotProcessingSettings()
            }
            .store(in: &automaticScreenshotSettingsCancellables)

        UserDefaults.standard
            .publisher(for: \.automaticScreenshotChangeThresholdPercent)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateAutomaticScreenshotProcessingSettings()
            }
            .store(in: &automaticScreenshotSettingsCancellables)

        UserDefaults.standard
            .publisher(for: \.automaticScreenshotDetectChangesInSharedRegionOnly)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateAutomaticScreenshotProcessingSettings()
            }
            .store(in: &automaticScreenshotSettingsCancellables)

        UserDefaults.standard
            .publisher(for: \.automaticScreenshotCropToSharedRegion)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateAutomaticScreenshotProcessingSettings()
            }
            .store(in: &automaticScreenshotSettingsCancellables)
    }

    convenience init(
        availableInputDevicesProvider: @escaping @Sendable () -> [MicrophoneDevice],
        defaultInputDeviceIDProvider: @escaping @Sendable () -> AudioDeviceID?
    ) {
        self.init(audioHardwareQueryService: AudioHardwareQueryService(
            availableInputDevicesProvider: availableInputDevicesProvider,
            defaultInputDeviceIDProvider: defaultInputDeviceIDProvider
        ))
    }

    func configureBatchTranscription(
        dbQueue: DatabaseQueue,
        managedRootURL: URL = BatchAudioStorage.managedRootURL,
        recoverExistingSessions: Bool = true,
        onRecoveryCompleted: (@MainActor @Sendable () async -> Void)? = nil
    ) {
        guard batchTranscriptionCoordinator == nil else { return }
        let coordinator = BatchTranscriptionCoordinator(
            dbQueue: dbQueue,
            managedRootURL: managedRootURL
        ) { [weak self] update in
            await self?.handleBatchTranscriptionUpdate(update)
        }
        batchTranscriptionCoordinator = coordinator
        onBatchTranscriptionRecoveryCompleted = onRecoveryCompleted
        guard recoverExistingSessions else { return }
        retryBatchTranscriptionRecovery()
    }

    func configureSearchIndexer(_ searchIndexer: SearchIndexer) {
        self.searchIndexer = searchIndexer
    }

    func retryBatchTranscriptionRecovery() {
        guard batchTranscriptionRecoveryTask == nil,
              let coordinator = batchTranscriptionCoordinator else { return }
        batchTranscriptionRecoveryTask = Task { [weak self] in
            guard let self else { return }
            defer { batchTranscriptionRecoveryTask = nil }
            do {
                try await coordinator.recoverAndEnqueue()
                guard !Task.isCancelled else { return }
                batchTranscriptionRecoveryAlert = nil
                await onBatchTranscriptionRecoveryCompleted?()
            } catch {
                ErrorReportingService.capture(error, context: ["source": "batchTranscriptionStartupRecovery"])
                batchTranscriptionRecoveryAlert = BatchTranscriptionRecoveryAlert(
                    message: error.localizedDescription
                )
            }
        }
    }

    func prepareForTermination() async -> String? {
        isTerminationRequested = true
        while case .starting = recordingLifecycle {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if case .recording = recordingLifecycle {
            stopListening()
        }
        await recordingStopTask?.value
        guard await retryFailedPersistenceIfNeeded() else {
            isTerminationRequested = false
            return errorMessage ?? L10n.recordingPersistenceRetryFailed
        }
        do {
            try await batchTranscriptionCoordinator?.shutdown()
            return nil
        } catch {
            isTerminationRequested = false
            ErrorReportingService.capture(error, context: ["source": "batchTranscriptionTerminationPersistence"])
            return error.localizedDescription
        }
    }

    #if DEBUG
        func setFailedPersistenceServiceForTesting(_ service: MeetingPersistenceService) {
            failedPersistenceService = service
            failedPersistenceMeetingId = service.meetingId
        }

        func setBatchTranscriptionCoordinatorForTesting(_ coordinator: BatchTranscriptionCoordinator) {
            batchTranscriptionCoordinator = coordinator
        }
    #endif

    func retryBatchTranscription() {
        switch batchTranscriptionState {
        case let .failed(sessionId, _), let .interrupted(sessionId, false):
            guard canRetranscribeBatchAudio,
                  let meetingId = currentMeetingId else { return }
            presentBatchTranscriptionConfirmation(
                sessionId: sessionId,
                meetingId: meetingId,
                suggestedLocaleIdentifier: transcriptionLocale,
                dbQueue: currentDbQueue,
                vaultURL: currentVaultURL
            )
        case let .retranscriptionFailed(sessionId, _), let .interrupted(sessionId, true):
            guard let meetingId = currentMeetingId,
                  let dbQueue = currentDbQueue else { return }
            let expectedState = batchTranscriptionState
            Task {
                let sessionIds = await (try? Self.fetchRetryableBatchSessionIds(
                    meetingId: meetingId,
                    state: expectedState,
                    dbQueue: dbQueue
                )) ?? []
                guard !sessionIds.isEmpty,
                      currentMeetingId == meetingId,
                      batchTranscriptionState == expectedState else { return }
                retranscribableBatchSessionIds = sessionIds
                presentBatchRetranscriptionConfirmation(
                    sessionId: sessionIds.contains(sessionId) ? sessionId : sessionIds[sessionIds.count - 1],
                    sessionIds: sessionIds,
                    meetingId: meetingId
                )
            }
        default:
            return
        }
    }

    func presentBatchRetranscriptionConfirmation() {
        guard canRetranscribeBatchAudio,
              let meetingId = currentMeetingId,
              let sessionId = retranscribableBatchSessionIds.last else { return }
        presentBatchRetranscriptionConfirmation(
            sessionId: sessionId,
            sessionIds: retranscribableBatchSessionIds,
            meetingId: meetingId
        )
    }

    func presentAvailableBatchRetranscription() {
        guard !isListening else { return }
        switch batchTranscriptionState {
        case .awaitingConfirmation:
            presentBatchTranscriptionConfirmation()
        case .failed, .retranscriptionFailed, .interrupted:
            retryBatchTranscription()
        default:
            presentBatchRetranscriptionConfirmation()
        }
    }

    private func presentBatchRetranscriptionConfirmation(
        sessionId: UUID,
        sessionIds: [UUID],
        meetingId: UUID,
        dbQueue suppliedDbQueue: DatabaseQueue? = nil,
        vaultURL suppliedVaultURL: URL? = nil
    ) {
        let dbQueue = suppliedDbQueue ?? currentDbQueue
        let vaultURL = suppliedVaultURL ?? currentVaultURL
        let details = makeBatchTranscriptionConfirmationDetails(
            meetingId: meetingId,
            dbQueue: dbQueue
        )
        if let dbQueue, let vaultURL {
            batchSummaryContextsBySessionId[sessionId] = BatchSummaryContext(
                dbQueue: dbQueue,
                vaultURL: vaultURL,
                meetingName: details.meetingName
            )
        }
        let preferences = batchConfirmationPreferences(
            sessionId: sessionId,
            suggestedLocaleIdentifier: transcriptionLocale,
            dbQueue: dbQueue,
            confirmationSessionIds: sessionIds
        )
        pendingBatchTranscriptionConfirmation = BatchTranscriptionConfirmation(
            sessionId: sessionId,
            meetingId: meetingId,
            suggestedLocaleIdentifier: preferences.localeIdentifier,
            retainAudioAfterBatch: preferences.retainsAudio,
            initialLanguageSelection: preferences.languageSelection,
            automaticLanguageCandidateSnapshot: preferences.automaticLanguageCandidateSnapshot,
            purpose: .retranscription(sessionIds: sessionIds),
            initiallyGeneratesSummary: hasCurrentMeetingSummary
                || AppSettings.shared.generateSummaryAfterBatchTranscription,
            projectSelection: details.projectSelection
        )
    }

    func batchTranscriptionLocaleOptions(preferredIdentifier: String) -> [Locale] {
        var locales = AppSettings.shared.transcriptionLanguageScope == .all
            ? supportedLocales
            : filteredLocales
        if !locales.contains(where: { $0.identifier == preferredIdentifier }) {
            locales.append(Locale(identifier: preferredIdentifier))
        }
        return locales.sortedByLocalizedName()
    }

    func batchTranscriptionAutomaticLanguageCandidates(
        snapshot: BatchLanguageDetectionCandidateSnapshot? = nil
    ) -> BatchLanguageDetectionCandidates {
        if let snapshot {
            return BatchLanguageDetectionCandidateResolver.candidates(
                snapshot: snapshot,
                supportedLocales: supportedLocales
            )
        }
        let settings = AppSettings.shared
        return BatchLanguageDetectionCandidateResolver.candidates(
            scope: settings.transcriptionLanguageScope,
            enabledLocaleIdentifiers: settings.enabledLocaleIdentifiers,
            supportedLocales: supportedLocales
        )
    }

    private struct BatchTranscriptionConfirmationDetails {
        let projectSelection: BatchTranscriptionProjectSelection
        let meetingName: String
    }

    private func makeBatchTranscriptionConfirmationDetails(
        meetingId: UUID,
        dbQueue: DatabaseQueue?
    ) -> BatchTranscriptionConfirmationDetails {
        guard let dbQueue else {
            return BatchTranscriptionConfirmationDetails(
                projectSelection: .unavailable,
                meetingName: L10n.newMeeting
            )
        }

        do {
            let snapshot = try dbQueue.read { db -> (MeetingRecord, [ProjectRecord]) in
                guard let meeting = try MeetingRecord.fetchOne(db, key: meetingId) else {
                    throw SummaryGenerationPreparationError.meetingUnavailable
                }
                let projects = try ProjectRecord.fetchResolvedAll(vaultId: meeting.vaultId, in: db)
                return (meeting, projects)
            }
            return BatchTranscriptionConfirmationDetails(
                projectSelection: BatchTranscriptionProjectSelection(
                    projects: FlatProjectRow.buildRows(fromRecords: snapshot.1),
                    selectedProjectId: snapshot.0.projectId,
                    errorMessage: nil
                ),
                meetingName: snapshot.0.name.nilIfBlank ?? L10n.newMeeting
            )
        } catch {
            return BatchTranscriptionConfirmationDetails(
                projectSelection: BatchTranscriptionProjectSelection(
                    projects: [],
                    selectedProjectId: nil,
                    errorMessage: error.localizedDescription
                ),
                meetingName: L10n.newMeeting
            )
        }
    }

    func assignPendingBatchTranscriptionProject(_ projectId: UUID?) -> String? {
        guard let confirmation = pendingBatchTranscriptionConfirmation else { return L10n.meetingUnavailable }
        if let errorMessage = confirmation.projectSelection.errorMessage { return errorMessage }
        guard let context = batchSummaryContextsBySessionId[confirmation.sessionId] else { return nil }

        do {
            let repository = MeetingRepository(dbQueue: context.dbQueue)
            guard let meeting = try repository.fetchMeeting(id: confirmation.meetingId),
                  let vault = try repository.fetchAllVaults().first(where: { $0.id == meeting.vaultId }),
                  vault.url.standardizedFileURL == context.vaultURL.standardizedFileURL else {
                return L10n.meetingUnavailable
            }
            guard meeting.projectId != projectId else { return nil }

            try ProjectWorkspaceService(repository: repository, vault: vault)
                .moveMeeting(id: meeting.id, toProjectId: projectId)

            if currentMeetingId == meeting.id, currentDbQueue === context.dbQueue {
                let project = try projectId.flatMap(repository.fetchProject(id:))
                setExplicitProjectContext(
                    projectURL: project.map { context.vaultURL.appending(path: $0.path, directoryHint: .isDirectory) },
                    projectId: projectId,
                    projectName: project?.path
                )
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func assignCurrentMeetingProject(_ projectId: UUID?) -> String? {
        guard let meetingId = currentMeetingId,
              let dbQueue = currentDbQueue,
              let vaultURL = currentVaultURL else {
            return L10n.meetingUnavailable
        }

        do {
            let repository = MeetingRepository(dbQueue: dbQueue)
            guard let meeting = try repository.fetchMeeting(id: meetingId),
                  let vault = try repository.fetchAllVaults().first(where: { $0.id == meeting.vaultId }),
                  vault.url.standardizedFileURL == vaultURL.standardizedFileURL else {
                return L10n.meetingUnavailable
            }
            guard meeting.projectId != projectId else { return nil }

            try ProjectWorkspaceService(repository: repository, vault: vault)
                .moveMeeting(id: meeting.id, toProjectId: projectId)
            let project = try projectId.flatMap(repository.fetchProject(id:))
            setExplicitProjectContext(
                projectURL: project.map { vaultURL.appending(path: $0.path, directoryHint: .isDirectory) },
                projectId: projectId,
                projectName: project?.path
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func presentBatchTranscriptionConfirmation() {
        guard !isListening,
              case let .awaitingConfirmation(sessionId) = batchTranscriptionState,
              let meetingId = currentMeetingId else { return }
        presentBatchTranscriptionConfirmation(
            sessionId: sessionId,
            meetingId: meetingId,
            suggestedLocaleIdentifier: transcriptionLocale,
            dbQueue: currentDbQueue,
            vaultURL: currentVaultURL
        )
    }

    func presentBatchTranscriptionConfirmation(
        sessionId: UUID,
        meetingId: UUID,
        dbQueue: DatabaseQueue
    ) async {
        await presentManualBatchTranscription(sessionId: sessionId, meetingId: meetingId, dbQueue: dbQueue)
    }

    func presentManualBatchTranscription(
        sessionId: UUID,
        meetingId: UUID,
        dbQueue: DatabaseQueue
    ) async {
        guard !isListening else { return }
        do {
            let snapshot = try await dbQueue.read { db -> (
                session: RecordingSessionRecord?,
                pendingRetranscriptionIds: [UUID],
                vaultURL: URL?
            ) in
                let session = try RecordingSessionRecord.fetchOne(db, key: sessionId)
                let pendingRetranscriptionIds = try RecordingSessionRecord
                    .filter(Column("meetingId") == meetingId)
                    .order(Column("startedAt").asc)
                    .fetchAll(db)
                    .filter(\.isBatchRetranscriptionPending)
                    .map(\.id)
                let vaultURL = try MeetingRecord.fetchOne(db, key: meetingId)
                    .flatMap { try VaultRecord.fetchOne(db, key: $0.vaultId) }?
                    .url
                return (session, pendingRetranscriptionIds, vaultURL)
            }
            guard !isListening else { return }
            if snapshot.session?.isBatchRetranscriptionPending == true,
               !snapshot.pendingRetranscriptionIds.isEmpty {
                presentBatchRetranscriptionConfirmation(
                    sessionId: sessionId,
                    sessionIds: snapshot.pendingRetranscriptionIds,
                    meetingId: meetingId,
                    dbQueue: dbQueue,
                    vaultURL: snapshot.vaultURL
                )
                return
            }
            presentBatchTranscriptionConfirmation(
                sessionId: sessionId,
                meetingId: meetingId,
                suggestedLocaleIdentifier: transcriptionLocale,
                dbQueue: dbQueue,
                vaultURL: snapshot.vaultURL
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func postponeBatchTranscription() {
        pendingBatchTranscriptionConfirmation = nil
    }

    func confirmBatchTranscription(
        languageSelection: BatchTranscriptionLanguageSelection,
        retainAudioAfterBatch: Bool,
        summaryGenerationOptions: SummaryGenerationOptions?
    ) {
        guard !isListening,
              let confirmation = pendingBatchTranscriptionConfirmation,
              let coordinator = batchTranscriptionCoordinator else { return }
        let automaticLanguageCandidates = batchTranscriptionAutomaticLanguageCandidates(
            snapshot: confirmation.automaticLanguageCandidateSnapshot
        )
        let selectedAutomaticLanguageCandidates = languageSelection == .automatic
            ? automaticLanguageCandidates.snapshot
            : nil
        let retryConfirmation = BatchTranscriptionConfirmation(
            sessionId: confirmation.sessionId,
            meetingId: confirmation.meetingId,
            suggestedLocaleIdentifier: confirmation.suggestedLocaleIdentifier,
            retainAudioAfterBatch: retainAudioAfterBatch,
            initialLanguageSelection: languageSelection,
            allowsRecordedLanguageSelection: confirmation.allowsRecordedLanguageSelection,
            automaticLanguageCandidateSnapshot: automaticLanguageCandidates.snapshot,
            purpose: confirmation.purpose,
            initiallyGeneratesSummary: summaryGenerationOptions != nil,
            projectSelection: makeBatchTranscriptionConfirmationDetails(
                meetingId: confirmation.meetingId,
                dbQueue: batchSummaryContextsBySessionId[confirmation.sessionId]?.dbQueue
            ).projectSelection
        )
        let batchSummaryContext = batchSummaryContextsBySessionId[confirmation.sessionId]
        updatePendingBatchSummaryRequest(
            sessionID: confirmation.sessionId,
            meetingID: confirmation.meetingId,
            options: summaryGenerationOptions
        )
        batchSummaryContextsBySessionId.removeValue(forKey: confirmation.sessionId)
        pendingBatchTranscriptionConfirmation = nil
        if currentMeetingId == confirmation.meetingId {
            batchTranscriptionState = .queued(sessionId: confirmation.sessionId)
            retranscribableBatchSessionIds = []
        }

        Task { [weak self] in
            await self?.performBatchTranscriptionConfirmation(.init(
                confirmation: confirmation,
                coordinator: coordinator,
                languageSelection: languageSelection,
                automaticLanguageCandidates: selectedAutomaticLanguageCandidates,
                retainAudioAfterBatch: retainAudioAfterBatch,
                retryConfirmation: retryConfirmation,
                batchSummaryContext: batchSummaryContext
            ))
        }
    }

    private struct BatchTranscriptionConfirmationExecution {
        let confirmation: BatchTranscriptionConfirmation
        let coordinator: BatchTranscriptionCoordinator
        let languageSelection: BatchTranscriptionLanguageSelection
        let automaticLanguageCandidates: BatchLanguageDetectionCandidateSnapshot?
        let retainAudioAfterBatch: Bool
        let retryConfirmation: BatchTranscriptionConfirmation
        let batchSummaryContext: BatchSummaryContext?
    }

    private func performBatchTranscriptionConfirmation(_ execution: BatchTranscriptionConfirmationExecution) async {
        do {
            let onConfirmed: @Sendable (BatchTranscriptionConfirmationService.Result) async -> Void = { [weak self] result in
                await self?.registerConfirmedBatchSummarySessions(
                    anchorSessionID: execution.confirmation.sessionId,
                    result: result
                )
            }
            switch execution.confirmation.purpose {
            case .initialOrRetry:
                try await execution.coordinator.confirmAndEnqueue(
                    sessionId: execution.confirmation.sessionId,
                    languageSelection: execution.languageSelection,
                    automaticLanguageCandidates: execution.automaticLanguageCandidates,
                    retainAudioAfterBatch: execution.retainAudioAfterBatch,
                    onConfirmed: onConfirmed
                )
            case let .retranscription(sessionIds):
                try await execution.coordinator.confirmRetranscriptionAndEnqueue(
                    sessionIds: sessionIds,
                    languageSelection: execution.languageSelection,
                    automaticLanguageCandidates: execution.automaticLanguageCandidates,
                    retainAudioAfterBatch: execution.retainAudioAfterBatch,
                    onConfirmed: onConfirmed
                )
            }
        } catch {
            restoreBatchTranscriptionConfirmation(execution, error: error)
        }
    }

    private func restoreBatchTranscriptionConfirmation(
        _ execution: BatchTranscriptionConfirmationExecution,
        error: Error
    ) {
        let confirmation = execution.confirmation
        if let job = pendingBatchSummaryRequestsBySessionId[confirmation.sessionId]?.job {
            failBatchTranscription(in: job, message: error.localizedDescription)
        }
        if let batchSummaryContext = execution.batchSummaryContext {
            batchSummaryContextsBySessionId[confirmation.sessionId] = batchSummaryContext
        }
        if currentMeetingId == confirmation.meetingId {
            switch confirmation.purpose {
            case .initialOrRetry:
                batchTranscriptionState = .awaitingConfirmation(sessionId: confirmation.sessionId)
            case let .retranscription(sessionIds):
                batchTranscriptionState = nil
                retranscribableBatchSessionIds = sessionIds
            }
        }
        errorMessage = error.localizedDescription
        pendingBatchTranscriptionConfirmation = execution.retryConfirmation
        MainWindowOpener.shared.openMainWindow()
    }

    private func updatePendingBatchSummaryRequest(
        sessionID: UUID,
        meetingID: UUID,
        options: SummaryGenerationOptions?
    ) {
        removePendingBatchSummaryFlow(for: sessionID, removesJobFromDisplay: true)
        guard let options,
              let context = batchSummaryContextsBySessionId[sessionID] else {
            return
        }

        let job = makeBatchSummaryGenerationJob(
            meetingID: meetingID,
            options: options,
            meetingName: context.meetingName
        )
        pendingBatchSummaryRequestsBySessionId[sessionID] = PendingBatchSummaryRequest(
            sessionID: sessionID,
            meetingId: meetingID,
            options: options,
            dbQueue: context.dbQueue,
            vaultURL: context.vaultURL,
            job: job
        )
        summaryGenerationJobs.append(job)
    }

    private func removePendingBatchSummaryFlow(for sessionID: UUID, removesJobFromDisplay: Bool) {
        guard let request = pendingBatchSummaryRequestsBySessionId[sessionID] else { return }
        removeSessionAliases(for: request)
        if removesJobFromDisplay {
            summaryGenerationJobs.removeAll { $0.id == request.job.id }
        }
    }

    private func registerConfirmedBatchSummarySessions(
        anchorSessionID: UUID,
        result: BatchTranscriptionConfirmationService.Result
    ) {
        guard let request = pendingBatchSummaryRequestsBySessionId[anchorSessionID],
              request.meetingId == result.meetingId else { return }
        removeSessionAliases(for: request)
        request.sessionIDs = Set(result.sessionIds)
        request.completedSessionIDs.formIntersection(request.sessionIDs)
        request.transcriptionProgressBySessionID = request.transcriptionProgressBySessionID.filter {
            request.sessionIDs.contains($0.key)
        }
        for sessionID in request.sessionIDs {
            pendingBatchSummaryRequestsBySessionId[sessionID] = request
        }
        updateBatchSummaryJobProgress(request)
    }

    private func makeBatchSummaryGenerationJob(
        meetingID: UUID,
        options: SummaryGenerationOptions,
        meetingName: String
    ) -> SummaryGenerationJob {
        let job = SummaryGenerationJob(
            meetingId: meetingID,
            meetingName: meetingName,
            includesTranscription: true
        )
        job.configureExports(options.exportOptions)
        return job
    }

    private func failBatchTranscription(in job: SummaryGenerationJob, message: String) {
        job.progress.transcription = .failed(message)
        job.progress.transcriptionProgress = nil
        job.progress.summaryGeneration = .skipped
        job.progress.vaultExport = .skipped
        job.progress.googleDocsExport = .skipped
    }

    func discardFailedBatchTranscription() {
        guard case let .failed(sessionId, _) = batchTranscriptionState,
              let meetingId = currentMeetingId,
              let dbQueue = currentDbQueue else { return }
        Task {
            do {
                let repository = MeetingRepository(dbQueue: dbQueue)
                guard try await repository.discardFailedBatchSessionSafely(id: sessionId) else { return }
                removePendingBatchSummaryFlow(for: sessionId, removesJobFromDisplay: false)
                batchSummaryContextsBySessionId.removeValue(forKey: sessionId)
                try refreshBatchTranscriptionState(meetingId: meetingId, dbQueue: dbQueue)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelFailedBatchRetranscription() {
        switch batchTranscriptionState {
        case .retranscriptionFailed, .interrupted(_, true):
            break
        default:
            return
        }
        guard let meetingId = currentMeetingId,
              let dbQueue = currentDbQueue else { return }
        Task {
            do {
                guard let sessionIds = await Self.pendingBatchRetranscriptionSessionIds(
                    meetingId: meetingId,
                    dbQueue: dbQueue
                ),
                    !sessionIds.isEmpty else { return }
                _ = try await BatchTranscriptionConfirmationService.cancelRetranscription(
                    sessionIds: sessionIds,
                    dbQueue: dbQueue
                )
                for sessionID in sessionIds {
                    removePendingBatchSummaryFlow(for: sessionID, removesJobFromDisplay: false)
                }
                guard currentMeetingId == meetingId else { return }
                batchTranscriptionState = nil
                retranscribableBatchSessionIds = sessionIds
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshBatchTranscriptionState(meetingId: UUID, dbQueue: DatabaseQueue) throws {
        let (state, retryableSessionIds) = try dbQueue.read { db in
            let sessions = try RecordingSessionRecord
                .filter(Column("meetingId") == meetingId)
                .order(Column("startedAt").asc)
                .fetchAll(db)
            let state = sessions
                .reversed()
                .compactMap { BatchTranscriptionState.derive(from: $0) }
                .first(where: \.blocksSummaryGeneration)
            let eligibleSessionIds = try Self.fetchEligibleBatchAudioSessionIds(meetingId: meetingId, db: db)
            return (
                state,
                Self.retryableBatchSessionIds(
                    state: state,
                    sessions: sessions,
                    eligibleSessionIds: eligibleSessionIds
                )
            )
        }
        guard currentMeetingId == meetingId else { return }
        batchTranscriptionState = state
        retranscribableBatchSessionIds = retryableSessionIds
    }

    func handleBatchTranscriptionUpdate(_ update: BatchTranscriptionUpdate) async {
        recordBatchTranscriptionTelemetry(update.state)
        let isVisibleMeeting = currentMeetingId == update.meetingId
        if !isVisibleMeeting, update.state.changesUnprocessedRecordingsProjection {
            offscreenBatchTranscriptionChangeToken &+= 1
        }
        if isVisibleMeeting,
           !(isBatchRecording && recordingMeetingId == update.meetingId) {
            batchTranscriptionState = update.state
            switch update.state {
            case .failed, .retranscriptionFailed, .interrupted:
                let sessionIds = await (try? Self.fetchRetryableBatchSessionIds(
                    meetingId: update.meetingId,
                    state: update.state,
                    dbQueue: currentDbQueue
                )) ?? []
                if currentMeetingId == update.meetingId, batchTranscriptionState == update.state {
                    retranscribableBatchSessionIds = sessionIds
                }
            default:
                break
            }
        }
        updatePendingBatchSummaryProgress(for: update)
        guard case .completed = update.state else { return }
        conversationMetricsStore.invalidate(meetingId: update.meetingId)
        if isVisibleMeeting, canReloadMeetingAfterBatchCompletion(update.meetingId) {
            await reloadCurrentMeetingAfterBatchCompletion(meetingId: update.meetingId)
        }
        generatePendingBatchSummaryIfReady(meetingId: update.meetingId)
    }

    private func recordBatchTranscriptionTelemetry(_ state: BatchTranscriptionState) {
        let sessionID = state.sessionId
        switch state {
        case .queued, .running:
            guard activeBatchTelemetrySessionIDs.insert(sessionID).inserted else { return }
            usageTelemetryReporter(.transcription(.started, mode: .batch))
        case .completed:
            guard activeBatchTelemetrySessionIDs.remove(sessionID) != nil else { return }
            usageTelemetryReporter(.transcription(.completed, mode: .batch))
        case .failed, .retranscriptionFailed, .interrupted:
            guard activeBatchTelemetrySessionIDs.remove(sessionID) != nil else { return }
            usageTelemetryReporter(.transcription(.failed(.transcription), mode: .batch))
        case .recording, .awaitingConfirmation:
            break
        }
    }

    private func updatePendingBatchSummaryProgress(for update: BatchTranscriptionUpdate) {
        let sessionID = update.state.sessionId
        guard let request = pendingBatchSummaryRequestsBySessionId[sessionID],
              !request.job.progress.transcription.isFailed else { return }
        let progress: Double
        switch update.state {
        case .recording, .awaitingConfirmation, .queued:
            progress = 0
        case let .running(_, batchProgress):
            progress = batchProgress.map { batchProgress in
                guard batchProgress.totalFileCount > 0 else { return 0.0 }
                return min(Double(batchProgress.completedFileCount) / Double(batchProgress.totalFileCount), 1)
            } ?? 0
        case .completed:
            request.completedSessionIDs.insert(sessionID)
            progress = 1
        case .interrupted:
            failBatchTranscription(in: request.job, message: L10n.batchTranscriptionInterrupted)
            return
        case let .failed(_, message), let .retranscriptionFailed(_, message):
            failBatchTranscription(in: request.job, message: message)
            return
        }
        request.transcriptionProgressBySessionID[sessionID] = progress
        updateBatchSummaryJobProgress(request)
    }

    private func updateBatchSummaryJobProgress(_ request: PendingBatchSummaryRequest) {
        if request.isTranscriptionCompleted {
            request.job.progress.transcription = .completed
            request.job.progress.transcriptionProgress = nil
        } else {
            request.job.progress.transcription = .running
            request.job.progress.transcriptionProgress = request.transcriptionProgress
        }
    }

    private func canReloadMeetingAfterBatchCompletion(_ meetingId: UUID) -> Bool {
        !isListening || recordingMeetingId != meetingId
    }

    private func reloadCurrentMeetingAfterBatchCompletion(meetingId: UUID) async {
        guard let dbQueue = currentDbQueue,
              let vaultURL = currentVaultURL,
              currentMeetingId == meetingId else { return }
        let projectionGeneration = summaryProjectionGeneration
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try Self.fetchLoadedMeetingData(
                    meetingId: meetingId,
                    dbQueue: dbQueue,
                    vaultURL: vaultURL
                )
            }.value
            guard currentMeetingId == meetingId,
                  canReloadMeetingAfterBatchCompletion(meetingId) else { return }
            store.recordingStartTime = loaded.recordingStartedAt
            store.loadRecordingSessions(loaded.recordingSessions)
            store.configurePaging(
                meetingId: meetingId,
                loader: TranscriptPageLoader(dbQueue: dbQueue),
                initialPage: loaded.initialTranscriptPage
            )
            applyLoadedDetail(loaded, expectedProjectionGeneration: projectionGeneration)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func bindStoreSegments() {
        currentMeetingHasTranscriptSegments = store.segments.contains(where: \.isConfirmed)
        storeSegmentsCancellable = store.$segments
            .map { $0.contains(where: \.isConfirmed) }
            .removeDuplicates()
            .sink { [weak self] hasSegments in
                self?.currentMeetingHasTranscriptSegments = hasSegments
            }
    }

    /// supportedLocales と設定から filteredLocales を再計算する。
    private func updateFilteredLocales() {
        let settings = AppSettings.shared
        let enabled = settings.enabledLocaleIdentifiers
        if settings.transcriptionLanguageScope == .all {
            filteredLocales = supportedLocales
        } else {
            filteredLocales = supportedLocales.filter { locale in
                enabled.contains(locale.identifier)
                    || locale.identifier == transcriptionLocale
                    || locale.identifier == liveSubtitleLocale
            }
        }
    }

    nonisolated static func resolvedSupportedLocaleIdentifier(
        preferredIdentifier: String,
        supportedLocales: [Locale]
    ) -> String {
        TranscriptionLocaleResolver.resolvedSupportedLocaleIdentifier(
            preferredIdentifier: preferredIdentifier,
            supportedLocales: supportedLocales
        )
    }

    private func resolvedTranscriptionLocale() -> Locale {
        let resolvedIdentifier = Self.resolvedSupportedLocaleIdentifier(
            preferredIdentifier: transcriptionLocale,
            supportedLocales: supportedLocales
        )
        if transcriptionLocale != resolvedIdentifier {
            transcriptionLocale = resolvedIdentifier
            AppSettings.shared.transcriptionLocale = resolvedIdentifier
        }
        return Locale(identifier: resolvedIdentifier)
    }

    private func resolvedLiveRecognitionLocale(mode: TranscriptionMode? = nil) -> Locale {
        if (mode ?? activeTranscriptionMode ?? AppSettings.shared.transcriptionMode) == .realtime {
            return resolvedTranscriptionLocale()
        }
        let resolvedIdentifier = Self.resolvedSupportedLocaleIdentifier(
            preferredIdentifier: liveSubtitleLocale,
            supportedLocales: supportedLocales
        )
        if liveSubtitleLocale != resolvedIdentifier {
            isSynchronizingLiveSubtitleLocale = true
            liveSubtitleLocale = resolvedIdentifier
            isSynchronizingLiveSubtitleLocale = false
            AppSettings.shared.liveSubtitleLocale = resolvedIdentifier
        }
        return Locale(identifier: resolvedIdentifier)
    }

    func refreshAvailableMicrophones() async {
        let snapshot = await audioHardwareQueryService.microphoneSnapshot()
        guard !Task.isCancelled else { return }
        let devices = snapshot.devices

        if devices != availableMicrophones {
            availableMicrophones = devices
        }
        if defaultInputDeviceID != snapshot.defaultDeviceID {
            defaultInputDeviceID = snapshot.defaultDeviceID
        }
        hasResolvedDefaultInputDevice = true

        if case let .device(currentMicrophoneID) = microphoneSelection,
           !devices.isEmpty,
           !devices.contains(where: { $0.id == currentMicrophoneID }) {
            microphoneSelection = .systemDefault
        }
    }

    private func refreshDefaultInputDevice() async {
        let deviceID = await audioHardwareQueryService.defaultInputDeviceID()
        guard !Task.isCancelled else { return }
        if defaultInputDeviceID != deviceID {
            defaultInputDeviceID = deviceID
        }
        hasResolvedDefaultInputDevice = true
    }

    private static let fileDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f
    }()

    private struct LoadedMeetingData {
        let recordingStartedAt: Date?
        let recordingSessionRecords: [RecordingSessionRecord]
        let recordingSessions: [RecordingSessionTimeline]
        let initialTranscriptPage: TranscriptPage
        let hasTranscriptSegments: Bool
        let screenshots: [MeetingScreenshotRecord]
        let summaryDocument: SummaryDocument?
        let googleFileId: String?
        let lastSummaryURL: URL?
        let note: MeetingNoteRecord?
        let eligibleBatchAudioSessionIds: [UUID]
    }

    private nonisolated static func fetchLoadedMeetingData(
        meetingId: UUID,
        dbQueue: DatabaseQueue,
        vaultURL: URL
    ) throws -> LoadedMeetingData {
        let repo = MeetingRepository(dbQueue: dbQueue)
        let detail = try repo.fetchMeetingDetail(id: meetingId)
        let recordingSessions = detail.recordingSessions.map(RecordingSessionTimeline.init)
        let initialTranscriptPage = try repo.fetchTranscriptPage(
            forMeetingId: meetingId,
            direction: .latest,
            limit: TranscriptStore.initialPageSize
        )
        let vaultExport = detail.summaryExports.first(where: { $0.type == .vault })
        let googleDocsExport = detail.summaryExports.first(where: { $0.type == .googleDocs })

        let lastSummaryURL: URL? = if detail.summary != nil {
            SummaryService.findSummaryFile(
                storedRelativePath: vaultExport?.vaultRelativePath,
                vaultURL: vaultURL
            )
        } else {
            nil
        }

        let eligibleBatchAudioSessionIds = try fetchEligibleBatchAudioSessionIds(
            meetingId: meetingId,
            dbQueue: dbQueue
        )

        return try LoadedMeetingData(
            recordingStartedAt: detail.meeting?.effectiveRecordingStartedAt,
            recordingSessionRecords: detail.recordingSessions,
            recordingSessions: recordingSessions,
            initialTranscriptPage: initialTranscriptPage,
            hasTranscriptSegments: !initialTranscriptPage.segments.isEmpty,
            screenshots: detail.screenshots,
            summaryDocument: detail.summary?.loadDocument(),
            googleFileId: googleDocsExport?.googleDocumentID,
            lastSummaryURL: lastSummaryURL,
            note: detail.note,
            eligibleBatchAudioSessionIds: eligibleBatchAudioSessionIds
        )
    }

    private nonisolated static func fetchEligibleBatchAudioSessionIds(
        meetingId: UUID,
        dbQueue: DatabaseQueue
    ) throws -> [UUID] {
        try dbQueue.read { db in
            try fetchEligibleBatchAudioSessionIds(meetingId: meetingId, db: db)
        }
    }

    private nonisolated static func fetchRetryableBatchSessionIds(
        meetingId: UUID,
        state: BatchTranscriptionState?,
        dbQueue: DatabaseQueue?
    ) async throws -> [UUID] {
        guard let dbQueue else { return [] }
        return try await dbQueue.read { db in
            let eligibleSessionIds = try fetchEligibleBatchAudioSessionIds(meetingId: meetingId, db: db)
            let sessions = try RecordingSessionRecord
                .filter(Column("meetingId") == meetingId)
                .order(Column("startedAt").asc)
                .fetchAll(db)
            return retryableBatchSessionIds(
                state: state,
                sessions: sessions,
                eligibleSessionIds: eligibleSessionIds
            )
        }
    }

    private nonisolated static func retryableBatchSessionIds(
        state: BatchTranscriptionState?,
        sessions: [RecordingSessionRecord],
        eligibleSessionIds: [UUID]
    ) -> [UUID] {
        let eligibleSessionIdSet = Set(eligibleSessionIds)
        switch state {
        case let .failed(sessionId, _):
            return eligibleSessionIdSet.contains(sessionId) ? [sessionId] : []
        case let .interrupted(sessionId, false):
            return eligibleSessionIdSet.contains(sessionId) ? [sessionId] : []
        case .interrupted(_, true):
            let pendingSessionIds = sessions.filter(\.isBatchRetranscriptionPending).map(\.id)
            guard !pendingSessionIds.isEmpty,
                  pendingSessionIds.allSatisfy(eligibleSessionIdSet.contains) else { return [] }
            return pendingSessionIds
        case .retranscriptionFailed:
            let pendingSessionIds = sessions.filter(\.isBatchRetranscriptionPending).map(\.id)
            guard !pendingSessionIds.isEmpty,
                  pendingSessionIds.allSatisfy(eligibleSessionIdSet.contains) else { return [] }
            return pendingSessionIds
        default:
            return eligibleSessionIds
        }
    }

    private nonisolated static func fetchEligibleBatchAudioSessionIds(
        meetingId: UUID,
        db: Database
    ) throws -> [UUID] {
        try UUID.fetchAll(
            db,
            sql: """
                SELECT DISTINCT sessions.id
                FROM recording_sessions AS sessions
                JOIN recording_audio_segments AS segments
                  ON segments.recordingSessionId = sessions.id
                JOIN recording_audio_segment_ranges AS ranges
                  ON ranges.audioSegmentId = segments.id
                WHERE sessions.meetingId = ?
                  AND sessions.transcriptionMode = ?
                  AND sessions.batchDiscardedAt IS NULL
                  AND (
                      (
                          sessions.batchCompletedAt IS NOT NULL
                          AND sessions.retainAudioAfterBatch = 1
                          AND (sessions.batchLastAttemptAt IS NULL OR sessions.batchLastAttemptAt <= sessions.batchCompletedAt)
                      )
                      OR sessions.batchLastError IS NOT NULL
                  )
                  AND segments.state = ?
                  AND segments.purgedAt IS NULL
                  AND NOT EXISTS (
                      SELECT 1 FROM recording_audio_segments AS candidate
                      WHERE candidate.recordingSessionId = sessions.id
                        AND (
                            candidate.state != ?
                            OR candidate.purgedAt IS NOT NULL
                            OR NOT EXISTS (
                                SELECT 1 FROM recording_audio_segment_ranges AS candidateRanges
                                WHERE candidateRanges.audioSegmentId = candidate.id
                            )
                        )
                  )
                ORDER BY sessions.startedAt
            """,
            arguments: [
                meetingId,
                TranscriptionMode.batch.rawValue,
                RecordingAudioSegmentState.ready.rawValue,
                RecordingAudioSegmentState.ready.rawValue,
            ]
        )
    }

    // MARK: - Meeting Loading

    /// DB から文字起こしのセグメントを読み込んで表示する。
    /// 録音中でも呼び出し可能。録音パイプラインはバックグラウンドで継続する。
    func loadMeeting(
        _ meetingId: UUID,
        dbQueue: DatabaseQueue,
        projectURL: URL?,
        projectId: UUID?,
        projectName: String? = nil,
        vaultURL: URL
    ) {
        guard !isFinalizingRecording else { return }
        if case .starting = recordingLifecycle { return }

        // 録音中に録音対象のトランスクリプトを選択した場合はライブ表示に復帰
        if isListening, meetingId == recordingMeetingId {
            returnToRecordingMeeting()
            return
        }

        // 録音中の場合、録音コンテキストをバックアップして表示用ストアを差し替え
        if isListening {
            saveRecordingContextIfNeeded()
            meetingLoadTask?.cancel()
            saveNoteImmediately()
            store = TranscriptStore()
        } else {
            resetMeetingState()
        }
        draftMeeting = nil

        setMeetingContext(
            id: meetingId,
            dbQueue: dbQueue,
            projectURL: projectURL,
            projectId: projectId,
            projectName: projectName,
            vaultURL: vaultURL
        )

        let transcriptPageLoader = TranscriptPageLoader(dbQueue: dbQueue)
        store.prepareForMeetingLoading(meetingId: meetingId, loader: transcriptPageLoader)
        startMeetingLoad(
            meetingId: meetingId,
            dbQueue: dbQueue,
            vaultURL: vaultURL,
            transcriptPageLoader: transcriptPageLoader
        )
    }

    func retryInitialMeetingLoad() {
        guard store.requiresFullMeetingReload,
              let meetingId = currentMeetingId,
              let dbQueue = currentDbQueue,
              let vaultURL = currentVaultURL else { return }
        let transcriptPageLoader = TranscriptPageLoader(dbQueue: dbQueue)
        store.prepareForMeetingLoading(meetingId: meetingId, loader: transcriptPageLoader)
        startMeetingLoad(
            meetingId: meetingId,
            dbQueue: dbQueue,
            vaultURL: vaultURL,
            transcriptPageLoader: transcriptPageLoader
        )
    }

    func loadCurrentMeetingConversationMetrics() async {
        guard let meetingId = currentMeetingId,
              let dbQueue = currentDbQueue,
              !isCurrentMeetingConversationAnalysisPending,
              currentMeetingHasTranscriptSegments else { return }
        await conversationMetricsStore.load(meetingId: meetingId, dbQueue: dbQueue)
    }

    private func startMeetingLoad(
        meetingId: UUID,
        dbQueue: DatabaseQueue,
        vaultURL: URL,
        transcriptPageLoader: TranscriptPageLoader
    ) {
        meetingLoadTask?.cancel()
        meetingLoadGeneration &+= 1
        let generation = meetingLoadGeneration
        let projectionGeneration = summaryProjectionGeneration
        meetingLoadTask = Task { [weak self, meetingId, dbQueue, vaultURL, transcriptPageLoader] in
            guard let self else { return }

            let loaded: LoadedMeetingData
            do {
                loaded = try await Task.detached(priority: .userInitiated) {
                    try Self.fetchLoadedMeetingData(
                        meetingId: meetingId,
                        dbQueue: dbQueue,
                        vaultURL: vaultURL
                    )
                }.value
            } catch is CancellationError {
                return
            } catch {
                captionViewModelLogger.error("Failed to load meeting \(meetingId): \(error)")
                ErrorReportingService.capture(error, context: ["source": "loadMeeting"])
                if !Task.isCancelled,
                   self.meetingLoadGeneration == generation,
                   self.currentMeetingId == meetingId {
                    self.store.failInitialMeetingLoad(error)
                }
                return
            }

            guard !Task.isCancelled,
                  self.meetingLoadGeneration == generation,
                  self.currentMeetingId == meetingId else { return }

            self.store.recordingStartTime = loaded.recordingStartedAt
            self.store.loadRecordingSessions(loaded.recordingSessions)
            self.store.configurePaging(
                meetingId: meetingId,
                loader: transcriptPageLoader,
                initialPage: loaded.initialTranscriptPage
            )
            self.applyLoadedDetail(
                loaded,
                expectedProjectionGeneration: projectionGeneration
            )
            self.generatePendingBatchSummaryIfReady(meetingId: meetingId)
        }
    }

    /// 文字起こしを開始せずに空の MeetingRecord を作成し、表示対象としてセットする。
    func createEmptyMeeting(
        dbQueue: DatabaseQueue,
        projectURL: URL?,
        vaultId: UUID,
        projectId: UUID?,
        name: String = "",
        projectName: String? = nil,
        vaultURL: URL
    ) {
        guard !isRecordingStartPending, !isFinalizingRecording else { return }

        resetMeetingState()
        draftMeeting = nil

        let meetingId = UUID.v7()
        let now = Date()
        let record = MeetingRecord(
            id: meetingId,
            vaultId: vaultId,
            projectId: projectId,
            name: name,
            createdAt: now,
            updatedAt: now
        )
        try? dbQueue.write { db in
            try record.insert(db)
        }

        setMeetingContext(
            id: meetingId,
            dbQueue: dbQueue,
            projectURL: projectURL,
            projectId: projectId,
            projectName: projectName,
            vaultURL: vaultURL
        )
    }

    func beginDraftMeeting(
        from event: CalendarEvent? = nil,
        dbQueue: DatabaseQueue,
        projectURL: URL? = nil,
        projectId: UUID? = nil,
        projectName: String? = nil,
        vaultURL: URL
    ) {
        guard !isRecordingStartPending, !isFinalizingRecording else { return }

        clearCurrentMeeting()
        let draftId = UUID.v7()
        currentMeetingId = nil
        currentProjectURL = projectURL
        currentProjectId = projectId
        currentProjectName = projectName
        currentVaultURL = vaultURL
        currentDbQueue = dbQueue
        draftMeeting = DraftMeeting(
            id: draftId,
            title: event?.title ?? "",
            linkedCalendarEvent: event,
            projectURL: projectURL,
            projectId: projectId,
            projectName: projectName
        )
        setupNoteAutoSave()
    }

    func restoreDraftMeeting(
        _ draftMeeting: DraftMeeting,
        noteText: String,
        dbQueue: DatabaseQueue,
        vaultURL: URL
    ) {
        beginDraftMeeting(
            from: draftMeeting.linkedCalendarEvent,
            dbQueue: dbQueue,
            projectURL: draftMeeting.projectURL,
            projectId: draftMeeting.projectId,
            projectName: draftMeeting.projectName,
            vaultURL: vaultURL
        )
        guard self.draftMeeting != nil else { return }
        self.draftMeeting = draftMeeting
        self.noteText = noteText
        setupNoteAutoSave()
    }

    func updateDraftMeetingTitle(_ title: String) {
        guard draftMeeting != nil else { return }
        draftMeeting?.title = title
    }

    func materializeDraftMeeting(
        projectURL: URL? = nil,
        projectId: UUID? = nil,
        projectName: String? = nil,
        customerIntelligenceIngestion: CustomerIntelligenceIngestionPolicy
    ) -> UUID? {
        guard !isRecordingStartPending else { return nil }
        if let currentMeetingId {
            return currentMeetingId
        }

        guard let draftMeeting,
              let dbQueue = currentDbQueue,
              let vault = AppSettings.shared.currentVault,
              let vaultURL = currentVaultURL else { return nil }

        let requestedProjectURL = projectURL ?? draftMeeting.projectURL ?? currentProjectURL
        let requestedProjectId = projectId ?? draftMeeting.projectId ?? currentProjectId
        let requestedProjectName = projectName ?? draftMeeting.projectName ?? currentProjectName
        let meetingId = UUID.v7()
        let now = Date.now
        let calendarEventKey = draftMeeting.linkedCalendarEvent?.key
        let assignedProjectId: UUID?
        do {
            assignedProjectId = try dbQueue.write { db in
                if let event = draftMeeting.linkedCalendarEvent {
                    try CalendarEventRecord.upsert(event: event, now: now, in: db)
                }
                let assignedProjectId = try MeetingRecord.resolvedProjectIdForNewMeeting(
                    requestedProjectId: requestedProjectId,
                    calendarEvent: draftMeeting.linkedCalendarEvent,
                    vaultId: vault.id,
                    allowsCalendarSeriesProjectInheritance: draftMeeting.allowsCalendarSeriesProjectInheritance,
                    in: db
                )
                let record = MeetingRecord(
                    id: meetingId,
                    vaultId: vault.id,
                    projectId: assignedProjectId,
                    name: draftMeeting.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    status: .transcriptNotFound,
                    duration: nil,
                    createdAt: now,
                    updatedAt: now,
                    calendarEventIcalUid: calendarEventKey?.icalUid,
                    calendarEventRecurrenceId: calendarEventKey?.recurrenceId
                )
                try record.insert(db)
                return assignedProjectId
            }
        } catch {
            errorMessage = error.localizedDescription
            ErrorReportingService.capture(error, context: ["source": "materializeDraftMeeting"])
            return nil
        }

        let resolvedProject = Self.projectContext(
            projectId: assignedProjectId,
            dbQueue: dbQueue,
            vaultURL: vaultURL
        )
        pendingDraftMaterializations.append(DraftMeetingMaterialization(
            draftID: draftMeeting.id,
            meetingID: meetingId
        ))
        setMeetingContext(
            id: meetingId,
            dbQueue: dbQueue,
            projectURL: resolvedProject?.url ?? requestedProjectURL,
            projectId: assignedProjectId,
            projectName: resolvedProject?.name ?? requestedProjectName,
            vaultURL: vaultURL
        )
        if customerIntelligenceIngestion == .afterMeetingPersistence,
           let event = draftMeeting.linkedCalendarEvent {
            CustomerIntelligenceIngestionService.schedule(
                calendarEvent: event,
                meetingId: meetingId,
                vaultId: vault.id,
                observedAt: now,
                dbQueue: dbQueue
            )
        }
        if !noteText.isEmpty {
            saveNoteImmediately()
        }
        return meetingId
    }

    /// 現在の文字起こし表示をクリアして初期状態に戻す。
    /// 録音中はバックグラウンド録音を維持したまま表示のみクリアする。
    func clearCurrentMeeting() {
        guard !isFinalizingRecording else { return }
        if case .starting = recordingLifecycle { return }
        meetingLoadTask?.cancel()
        meetingLoadGeneration &+= 1

        if isListening {
            saveRecordingContextIfNeeded()
            saveNoteImmediately()
            store = TranscriptStore()
            screenshotStore.clear()
            resetNoteState()
            resetSummaryState()
        } else {
            resetMeetingState()
        }
        currentMeetingId = nil
        currentProjectURL = nil
        currentProjectId = nil
        currentProjectName = nil
        currentVaultURL = nil
        draftMeeting = nil
        batchTranscriptionState = nil
        retranscribableBatchSessionIds = []
        conversationMetricsStore.reset(for: nil)
    }

    /// Project 管理へ移る際に、保存済み Meeting の表示だけを解除する。
    /// 未保存のカレンダー下書きは、別画面を開いただけで失われないよう保持する。
    func clearCurrentMeetingForProjectNavigation() {
        guard !hasDraftMeeting else { return }
        clearCurrentMeeting()
    }

    /// 録音対象のトランスクリプトに表示を復帰する。
    func returnToRecordingMeeting() {
        guard let ctx = recordingContext else { return }
        meetingLoadTask?.cancel()
        meetingLoadGeneration &+= 1
        saveNoteImmediately()

        // コンテキストを先に復元（store 代入時の objectWillChange で SwiftUI が再評価する際に
        // currentMeetingId 等が正しい値を返すようにする）
        currentMeetingId = ctx.meetingId
        currentProjectURL = ctx.projectURL
        currentProjectId = ctx.projectId
        currentProjectName = ctx.projectName
        currentVaultURL = ctx.vaultURL
        currentDbQueue = ctx.dbQueue
        replaceVisibleScreenshots(meetingID: ctx.meetingId, records: [])
        batchTranscriptionState = ctx.batchTranscriptionState
        retranscribableBatchSessionIds = []
        draftMeeting = nil
        conversationMetricsStore.reset(for: ctx.meetingId)

        store = ctx.store
        recordingContext = nil

        reloadMeetingDetail()
    }

    /// 現在の meetingId のノート・スクリーンショット・サマリーを DB から読み込み直す。
    private func reloadMeetingDetail() {
        guard let meetingId = currentMeetingId,
              let dbQueue = currentDbQueue,
              let vaultURL = currentVaultURL else { return }
        meetingLoadTask?.cancel()
        meetingLoadGeneration &+= 1
        let generation = meetingLoadGeneration
        let projectionGeneration = summaryProjectionGeneration
        meetingLoadTask = Task { [weak self, meetingId, dbQueue, vaultURL] in
            guard let self else { return }
            let loaded: LoadedMeetingData
            do {
                loaded = try await Task.detached(priority: .userInitiated) {
                    try Self.fetchLoadedMeetingData(
                        meetingId: meetingId,
                        dbQueue: dbQueue,
                        vaultURL: vaultURL
                    )
                }.value
            } catch {
                return
            }
            guard !Task.isCancelled,
                  self.meetingLoadGeneration == generation,
                  self.currentMeetingId == meetingId else { return }
            self.applyLoadedDetail(
                loaded,
                expectedProjectionGeneration: projectionGeneration
            )
        }
    }

    /// サマリーだけを DB から読み込み直す。
    /// MCP ヘルパーのような別プロセスの書き込みは GRDB の `ValueObservation` では検知できないため、
    /// Vault の変更通知を受けた側から呼ぶ。編集中のノートを上書きしないよう `reloadMeetingDetail` は使わない。
    func reloadSummaryDocument() {
        guard let meetingId = currentMeetingId,
              let dbQueue = currentDbQueue else { return }
        summaryReloadTask?.cancel()
        summaryProjectionGeneration &+= 1
        let generation = summaryProjectionGeneration
        summaryReloadTask = Task { [weak self, meetingId, dbQueue] in
            guard let self else { return }
            let document: SummaryDocument?
            do {
                document = try await self.summaryDocumentLoader(meetingId, dbQueue)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  self.summaryProjectionGeneration == generation,
                  self.currentMeetingId == meetingId else { return }
            self.currentSummaryDocument = document
        }
    }

    /// 読み込み済みデータのノート・スクリーンショット・サマリーを UI 状態に反映する。
    private func applyLoadedDetail(
        _ loaded: LoadedMeetingData,
        expectedProjectionGeneration: UInt64
    ) {
        currentMeetingHasTranscriptSegments = loaded.hasTranscriptSegments
        replaceVisibleScreenshots(meetingID: currentMeetingId, records: loaded.screenshots)
        if summaryProjectionGeneration == expectedProjectionGeneration {
            currentSummaryDocument = loaded.summaryDocument
            currentSummaryGoogleFileId = loaded.googleFileId
            lastSummaryURL = loaded.lastSummaryURL
        }
        noteText = loaded.note?.text ?? ""
        hasNote = loaded.note != nil
        currentNoteCreatedAt = loaded.note?.createdAt
        lastSavedNoteText = noteText
        let restoredBatchTranscriptionState = loaded.recordingSessionRecords
            .reversed()
            .compactMap { BatchTranscriptionState.derive(from: $0) }
            .first(where: \.blocksSummaryGeneration)
        batchTranscriptionState = restoredBatchTranscriptionState
        retranscribableBatchSessionIds = Self.retryableBatchSessionIds(
            state: restoredBatchTranscriptionState,
            sessions: loaded.recordingSessionRecords,
            eligibleSessionIds: loaded.eligibleBatchAudioSessionIds
        )
        setupNoteAutoSave()

        guard let coordinator = batchTranscriptionCoordinator,
              let visibleState = batchTranscriptionState else { return }
        Task {
            guard let restoredState = await coordinator.runningState(sessionId: visibleState.sessionId),
                  batchTranscriptionState?.sessionId == visibleState.sessionId else { return }
            batchTranscriptionState = batchTranscriptionState?
                .preferringMoreAdvancedRunningProgress(over: restoredState) ?? restoredState
        }
    }

    // MARK: - Private Helpers

    private func replaceVisibleScreenshots(
        meetingID: UUID?,
        records: [MeetingScreenshotRecord]
    ) {
        guard let meetingID else {
            screenshotStore.clear()
            return
        }
        screenshotStore.replace(meetingID: meetingID, records: records)
    }

    /// 録音コンテキストをバックアップする（初回ナビゲーション時のみ）。
    private func saveRecordingContextIfNeeded() {
        guard recordingContext == nil else { return }
        recordingContext = RecordingContext(
            meetingId: currentMeetingId,
            store: store,
            projectURL: currentProjectURL,
            projectId: currentProjectId,
            projectName: currentProjectName,
            vaultURL: currentVaultURL,
            dbQueue: currentDbQueue,
            batchTranscriptionState: batchTranscriptionState
        )
    }

    /// UI 状態をリセットし、次の文字起こし読み込みに備える。
    private func resetMeetingState() {
        saveNoteImmediately()
        meetingLoadTask?.cancel()
        meetingLoadGeneration &+= 1
        store.clear()
        screenshotStore.clear()
        resetNoteState()
        resetSummaryState()
        draftMeeting = nil
        batchTranscriptionState = nil
        retranscribableBatchSessionIds = []
        conversationMetricsStore.reset(for: nil)
    }

    private func resetSummaryState() {
        summaryReloadTask?.cancel()
        summaryReloadTask = nil
        summaryProjectionGeneration &+= 1
        currentSummaryDocument = nil
        currentSummaryGoogleFileId = nil
        lastSummaryURL = nil
        requestShowSummaryTab = false
    }

    /// 現在の文字起こしコンテキスト（ID・プロジェクト情報）をセットする。
    private func setMeetingContext(
        id: UUID,
        dbQueue: DatabaseQueue,
        projectURL: URL?,
        projectId: UUID?,
        projectName: String?,
        vaultURL: URL
    ) {
        currentMeetingId = id
        currentProjectURL = projectURL
        currentProjectId = projectId
        currentProjectName = projectName
        currentVaultURL = vaultURL
        currentDbQueue = dbQueue
        conversationMetricsStore.reset(for: id)
        screenshotStore.replace(meetingID: id, records: [])
        draftMeeting = nil
        resetSummaryState()
        setupNoteAutoSave()
    }

    private static func projectContext(
        projectId: UUID?,
        dbQueue: DatabaseQueue,
        vaultURL: URL
    ) -> (url: URL, name: String)? {
        guard let projectId,
              let project = try? dbQueue.read({ db in
                  try ProjectRecord.fetchResolved(id: projectId, in: db)
              }) else { return nil }

        return (
            vaultURL.appending(path: project.path, directoryHint: .isDirectory),
            project.path
        )
    }

    func setExplicitProjectContext(projectURL: URL?, projectId: UUID?, projectName: String?) {
        currentProjectURL = projectURL
        currentProjectId = projectId
        currentProjectName = projectName
        draftMeeting?.projectURL = projectURL
        draftMeeting?.projectId = projectId
        draftMeeting?.projectName = projectName
        draftMeeting?.allowsCalendarSeriesProjectInheritance = false
    }

    // MARK: - Analyzer Preparation

    func prepareAnalyzer() {
        isPreparingAnalyzer = true
        errorMessage = nil

        Task {
            do {
                guard SpeechTranscriber.isAvailable else {
                    self.isPreparingAnalyzer = false
                    self.errorMessage = L10n.speechRecognitionUnavailable
                    return
                }

                // サポート言語一覧を取得
                let locales = await SpeechTranscriber.supportedLocales
                self.supportedLocales = locales.sortedByLocalizedName()
                self.updateFilteredLocales()

                // モデルのダウンロードと準備確認
                let locale = self.resolvedLiveRecognitionLocale()
                try await SpeechTranscriberService.ensureModelInstalled(locale: locale)
                self.analyzerReady = true
                self.isPreparingAnalyzer = false
            } catch {
                self.isPreparingAnalyzer = false
                self.errorMessage = L10n.speechPreparationFailed(error.localizedDescription)
                ErrorReportingService.capture(error, context: ["source": "prepareAnalyzer"])
            }
        }
    }

    func handleMicrophoneSelectionChange(from oldSelection: MicrophoneSelection, to newSelection: MicrophoneSelection) {
        guard oldSelection != newSelection else { return }
        if case .starting = recordingLifecycle, let startingMicrophoneSelection {
            if newSelection != startingMicrophoneSelection {
                microphoneSelection = startingMicrophoneSelection
            }
            return
        }
        applyAudioSourceSelectionChange(source: .microphone) { self.microphoneSelection = oldSelection }
    }

    func handleSystemAudioSelectionChange(from oldValue: Bool, to newValue: Bool) {
        guard oldValue != newValue else { return }
        if case .starting = recordingLifecycle, let startingSystemAudioEnabled {
            if newValue != startingSystemAudioEnabled {
                isSystemAudioEnabled = startingSystemAudioEnabled
            }
            return
        }
        applyAudioSourceSelectionChange(source: .system) { self.isSystemAudioEnabled = oldValue }
    }

    private func applyTranscriptionLocaleChange(from oldLocale: String, to newLocale: String) {
        guard newLocale != oldLocale || !analyzerReady else { return }
        if case .starting = recordingLifecycle, let startingTranscriptionLocaleIdentifier {
            if newLocale != startingTranscriptionLocaleIdentifier {
                transcriptionLocale = startingTranscriptionLocaleIdentifier
            }
            AppSettings.shared.transcriptionLocale = startingTranscriptionLocaleIdentifier
            return
        }
        AppSettings.shared.transcriptionLocale = newLocale

        if isListening {
            enqueueRecordingConfiguration { [weak self] recordingSessionId in
                _ = await self?.rebuildPipelines(
                    reason: .transcriptionLocaleChange,
                    recordingSessionId: recordingSessionId
                )
            }
        } else if AppSettings.shared.transcriptionMode == .realtime {
            analyzerReady = false
            prepareAnalyzer()
        }
    }

    private func applyLiveSubtitleLocaleChange(from oldLocale: String, to newLocale: String) {
        guard newLocale != oldLocale else { return }
        if case .starting = recordingLifecycle, let startingLiveSubtitleLocaleIdentifier {
            if newLocale != startingLiveSubtitleLocaleIdentifier {
                isSynchronizingLiveSubtitleLocale = true
                liveSubtitleLocale = startingLiveSubtitleLocaleIdentifier
                isSynchronizingLiveSubtitleLocale = false
            }
            AppSettings.shared.liveSubtitleLocale = startingLiveSubtitleLocaleIdentifier
            return
        }
        AppSettings.shared.liveSubtitleLocale = newLocale
        guard (activeTranscriptionMode ?? AppSettings.shared.transcriptionMode) == .batch else { return }
        if isListening {
            enqueueRecordingConfiguration { [weak self] recordingSessionId in
                _ = await self?.rebuildPipelines(
                    reason: .liveSubtitleLocaleChange,
                    recordingSessionId: recordingSessionId
                )
            }
        } else {
            analyzerReady = false
            prepareAnalyzer()
        }
    }

    private func applyAudioSourceSelectionChange(
        source: RecordingAudioSource,
        restoreSelection: @escaping @MainActor () -> Void
    ) {
        guard isListening else { return }

        enqueueRecordingConfiguration { [weak self] recordingSessionId in
            guard let self else { return }
            let applied = await self.rebuildPipelines(
                reason: .audioSourceChange(source),
                recordingSessionId: recordingSessionId
            )
            if !applied {
                restoreSelection()
                if self.activeControllerSources.isEmpty {
                    self.stopListening()
                }
            }
        }
    }

    private enum PipelineRebuildReason {
        case transcriptionLocaleChange
        case liveSubtitleLocaleChange
        case audioSourceChange(RecordingAudioSource)
    }

    @discardableResult
    private func rebuildPipelines(
        reason: PipelineRebuildReason,
        recordingSessionId: UUID
    ) async -> Bool {
        guard recordingLifecycle == .recording(recordingSessionId) else { return false }
        resetAudioLevels(for: reason)
        do {
            let snapshot: RecordingSessionController.Snapshot
            switch reason {
            case .transcriptionLocaleChange:
                let locale = resolvedTranscriptionLocale()
                snapshot = try await recordingSessionController.changeTranscriptionLocale(
                    to: locale,
                    translateSegment: translationHandler(for: locale)
                )
            case .liveSubtitleLocaleChange:
                let locale = resolvedLiveRecognitionLocale(mode: .batch)
                snapshot = try await recordingSessionController.changeLiveRecognitionLocale(
                    to: locale,
                    translateSegment: translationHandler(for: locale)
                )
            case let .audioSourceChange(source):
                let locale = appliedLiveRecognitionLocale()
                snapshot = try await recordingSessionController.setSource(
                    controllerSourceConfiguration(for: source),
                    enabled: enabledRecordingAudioSources.contains(source),
                    translateSegment: translationHandler(for: locale)
                )
            }
            guard snapshot.sessionId == recordingSessionId else { return false }
            resetAudioLevels(for: reason)
            applyControllerSnapshot(snapshot)
            errorMessage = nil
            return true
        } catch {
            guard !Task.isCancelled,
                  recordingLifecycle == .recording(recordingSessionId) else { return false }
            if let snapshot = await recordingSessionController.snapshot(),
               snapshot.sessionId == recordingSessionId {
                resetAudioLevels(for: reason)
                applyControllerSnapshot(snapshot)
            }
            setPipelineRebuildError(error, reason: reason)
            return false
        }
    }

    private func enqueueRecordingConfiguration(
        _ operation: @escaping @MainActor (UUID) async -> Void
    ) {
        guard case let .recording(recordingSessionId) = recordingLifecycle else { return }

        nextRecordingConfigurationID += 1
        let operationID = nextRecordingConfigurationID
        let previousTask = recordingConfigurationTasks
            .max(by: { $0.key < $1.key })?
            .value
        let task = Task { @MainActor [weak self] in
            await previousTask?.value
            guard let self else { return }
            defer { self.recordingConfigurationTasks[operationID] = nil }
            guard !Task.isCancelled,
                  self.recordingLifecycle == .recording(recordingSessionId) else { return }
            await operation(recordingSessionId)
        }
        recordingConfigurationTasks[operationID] = task
    }

    private func setPipelineRebuildError(_ error: Error, reason: PipelineRebuildReason) {
        switch reason {
        case .transcriptionLocaleChange, .liveSubtitleLocaleChange:
            errorMessage = L10n.languageChangeFailed(error.localizedDescription)
        case .audioSourceChange:
            errorMessage = error.localizedDescription
        }
    }

    private func resetAudioLevels(for reason: PipelineRebuildReason) {
        switch reason {
        case .transcriptionLocaleChange, .liveSubtitleLocaleChange:
            for source in activeControllerSources {
                recordingAudioLevelStore.reset(source: source)
            }
        case let .audioSourceChange(source):
            recordingAudioLevelStore.reset(source: source)
        }
    }

    private func prepareRecordingStart(
        existingMeetingId: UUID?,
        recordingStartTime: Date
    ) {
        persistenceService = nil
        transcriptionEventPipeline = nil
        liveCaptionEventRelay = nil
        liveTranscriptRelay = nil
        stopAutomaticScreenshotCapture()

        if existingMeetingId == nil {
            store.recordingStartTime = recordingStartTime
        }
    }

    private func batchRecordingSampleRate(for plan: TranscriptionSessionPlan) -> Double? {
        guard plan.recordsBatchAudio else { return nil }
        return BatchAudioRecordingSession.standardSampleRate
    }

    private func prepareAndStartRecordingController(
        _ request: RecordingControllerStartRequest
    ) async throws {
        guard let transcriptionEventPipeline else {
            throw RecordingSessionControllerError.sessionNotPrepared
        }
        await transcriptionEventPipeline.start()
        try await recordingSessionController.prepare(
            RecordingSessionController.PreparationRequest(
                sessionId: request.sessionId,
                startedAt: request.startedAt,
                plan: request.plan,
                locale: request.transcriptionLocale,
                liveRecognitionLocale: request.liveRecognitionLocale,
                sources: controllerSourceConfigurations(),
                dbQueue: request.plan.recordsBatchAudio ? request.dbQueue : nil,
                meetingId: request.plan.recordsBatchAudio ? request.meetingId : nil,
                batchSampleRate: request.batchSampleRate,
                translateSegment: translationHandler(for: request.liveRecognitionLocale),
                batchScheduler: batchTranscriptionCoordinator
            )
        ) { event in
            await transcriptionEventPipeline.enqueue(event)
        } onRuntimeFailure: { [weak self] source, message, isFatal in
            self?.handleControllerRuntimeFailure(
                source: source,
                message: message,
                isFatal: isFatal,
                recordingSessionId: request.sessionId
            )
        } onAudioLevel: { [weak self] source, level in
            self?.handleControllerAudioLevel(
                source: source,
                level: level,
                recordingSessionId: request.sessionId
            )
        }
        let snapshot = try await recordingSessionController.startPrepared()
        applyControllerSnapshot(snapshot)
        if request.plan.recordsBatchAudio {
            batchTranscriptionState = .recording(sessionId: request.sessionId)
        }
    }

    private func canStartRecording() -> Bool {
        guard hasEnabledAudioSource else {
            errorMessage = L10n.noAudioSourceSelected
            return false
        }
        return true
    }

    private func markRecordingStarted(recordingSessionId: UUID) {
        guard recordingLifecycle == .starting(recordingSessionId) else { return }
        recordingLifecycle = .recording(recordingSessionId)
        startingMicrophoneSelection = nil
        startingSystemAudioEnabled = nil
        startingTranscriptionLocaleIdentifier = nil
        startingLiveSubtitleLocaleIdentifier = nil
        isListening = true
        errorMessage = pendingLiveSubtitleWarning
        pendingLiveSubtitleWarning = nil
        syncAutomaticScreenshotCaptureState()
    }

    private func startPersistence(_ request: PersistenceStartRequest) async throws {
        if let existingMeetingId = request.existingMeetingId {
            let service = try await MeetingPersistenceService.createAppending(
                store: store,
                dbQueue: request.dbQueue,
                existingMeetingId: existingMeetingId,
                recordingStartDate: request.recordingStartTime,
                recordingSessionId: request.recordingSessionId,
                transcriptionMode: request.transcriptionMode,
                persistencePolicy: request.persistencePolicy,
                retainAudioAfterBatch: request.retainAudioAfterBatch
            )
            persistenceService = service
            installTranscriptionEventPipeline(persistenceService: service)
            currentMeetingId = existingMeetingId
            store.attachPagingContext(
                meetingId: existingMeetingId,
                loader: TranscriptPageLoader(dbQueue: request.dbQueue)
            )
            return
        }

        let initialName = request.draftMeeting?.title.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? request.initialMeetingName.trimmingCharacters(in: .whitespacesAndNewlines)
        let service = try await MeetingPersistenceService.createNew(
            store: store,
            dbQueue: request.dbQueue,
            vaultId: request.vaultId,
            projectId: request.projectId,
            initialName: initialName,
            allowsCalendarSeriesProjectInheritance: request.draftMeeting?.allowsCalendarSeriesProjectInheritance ?? true,
            calendarEvent: request.draftMeeting?.linkedCalendarEvent,
            recordingSessionId: request.recordingSessionId,
            transcriptionMode: request.transcriptionMode,
            persistencePolicy: request.persistencePolicy,
            retainAudioAfterBatch: request.retainAudioAfterBatch
        )
        persistenceService = service
        installTranscriptionEventPipeline(persistenceService: service)
        currentMeetingId = service.meetingId
        screenshotStore.replace(meetingID: service.meetingId, records: [])
        store.attachPagingContext(
            meetingId: service.meetingId,
            loader: TranscriptPageLoader(dbQueue: request.dbQueue)
        )

        let resolvedProject = currentVaultURL.flatMap { vaultURL -> (url: URL, name: String)? in
            guard let projectName = service.projectName else { return nil }
            return (
                vaultURL.appending(path: projectName, directoryHint: .isDirectory),
                projectName
            )
        }
        let projectWasInherited = service.projectId != request.projectId
        currentProjectId = service.projectId
        if let resolvedProject {
            currentProjectURL = resolvedProject.url
            currentProjectName = resolvedProject.name
        } else if projectWasInherited {
            currentProjectURL = nil
            currentProjectName = nil
        }
    }

    private func installTranscriptionEventPipeline(persistenceService: MeetingPersistenceService) {
        let recordingTranscriptStore = store
        let liveCaptionEventRelay = LiveCaptionEventRelay { [weak self] events in
            for event in events {
                self?.handleObservedTranscriptionEvent(event)
            }
        }
        let liveTranscriptRelay = FinalizedLiveTranscriptRelay { [weak self] delivery in
            self?.forwardFinalizedLiveTranscript(delivery)
        }
        self.liveCaptionEventRelay = liveCaptionEventRelay
        self.liveTranscriptRelay = liveTranscriptRelay
        transcriptionEventPipeline = TranscriptionEventPipeline(
            uiSink: { [weak self] events in
                for event in events {
                    self?.handleTranscriptProjectionEvent(event)
                }
            },
            eventObserver: { event in
                await liveCaptionEventRelay.enqueue(event)
                guard case let .finalized(segment) = event,
                      segment.isConfirmed,
                      let sessionID = segment.sessionId else { return }
                await liveTranscriptRelay.enqueue(sessionID: sessionID, text: segment.text)
            },
            uiReloadSink: { [weak recordingTranscriptStore] in
                guard let recordingTranscriptStore else { return }
                _ = await recordingTranscriptStore.reloadLatestAfterUICompaction()
            },
            persistenceSink: { events in
                try await persistenceService.persist(events)
            },
            persistenceFlushSink: {
                try await persistenceService.flushPendingTranscriptEvents()
            },
            persistenceResetSink: {
                try await persistenceService.reset()
            }
        )
    }

    private func completePersistenceStart(existingMeetingId: UUID?, activeDraftMeeting: DraftMeeting?) {
        guard existingMeetingId == nil else { return }
        if let activeDraftMeeting, let currentMeetingId {
            pendingDraftMaterializations.append(DraftMeetingMaterialization(
                draftID: activeDraftMeeting.id,
                meetingID: currentMeetingId
            ))
        }
        if activeDraftMeeting == nil, draftMeeting != nil {
            resetNoteState()
        }
        draftMeeting = nil
        setupNoteAutoSave()
        if activeDraftMeeting != nil {
            saveNoteImmediately()
        }
    }

    func consumeDraftMaterializations() -> [DraftMeetingMaterialization] {
        defer { pendingDraftMaterializations.removeAll() }
        return pendingDraftMaterializations
    }

    private func handleRecordingStartFailure(
        _ error: Error,
        recordingSessionId: UUID,
        rollbackState: RecordingStartRollbackState,
        existingMeetingId: UUID?,
        meetingScope: UsageTelemetryEvent.MeetingScope,
        previousBatchTranscriptionState: BatchTranscriptionState?
    ) async {
        guard recordingLifecycle == .starting(recordingSessionId) else { return }
        let mode = UsageTelemetryEvent.TranscriptionModeValue(activeTranscriptionMode ?? .realtime)
        let sources = UsageTelemetryEvent.AudioSources(sources: activeControllerSources)
            ?? requestedTelemetryAudioSources()
        if let sources {
            usageTelemetryReporter(.recording(
                .failed(.start),
                mode: mode,
                sources: sources,
                meetingScope: meetingScope,
                duration: nil
            ))
        }
        if mode == .realtime {
            usageTelemetryReporter(.transcription(.failed(.start), mode: mode))
        }
        errorMessage = error.localizedDescription
        ErrorReportingService.capture(error, context: ["source": "startListening"])
        await recordingSessionController.abort()
        let stoppingLiveCaptionEventRelay = liveCaptionEventRelay
        if let transcriptionEventPipeline {
            do {
                try await transcriptionEventPipeline.finish()
            } catch {
                ErrorReportingService.capture(error, context: ["source": "startTranscriptionPersistence"])
            }
        }
        await stoppingLiveCaptionEventRelay?.finish()
        await liveTranscriptRelay?.finish()
        transcriptionEventPipeline = nil
        liveCaptionEventRelay = nil
        liveTranscriptRelay = nil
        stopAutomaticScreenshotCapture()
        await persistenceService?.cancel()
        persistenceService = nil
        activeTranscriptionMode = nil
        activeTranscriptionPlan = nil
        activeRecordingSessionId = nil
        activeRecordingTelemetryContext = nil
        setActiveControllerSources([])
        pendingRealtimeRecognitionFailure = nil
        pendingLiveSubtitleWarning = nil
        startingMicrophoneSelection = nil
        startingSystemAudioEnabled = nil
        startingTranscriptionLocaleIdentifier = nil
        startingLiveSubtitleLocaleIdentifier = nil
        liveCaptionStore.clear()
        store.clear()
        store.loadSegments(rollbackState.segments)
        store.loadRecordingSessions(rollbackState.recordingSessions)
        store.recordingStartTime = rollbackState.recordingStartTime
        recordingLifecycle = .idle
        batchTranscriptionState = previousBatchTranscriptionState
        if existingMeetingId == nil {
            currentMeetingId = nil
        }
        if let preservedDraftContext = rollbackState.preservedDraftContext {
            let restoredDraftMeeting: DraftMeeting = if let draftMeeting,
                                                        draftMeeting.id == preservedDraftContext.meeting.id {
                draftMeeting
            } else {
                preservedDraftContext.meeting
            }
            draftMeeting = restoredDraftMeeting
            currentProjectURL = restoredDraftMeeting.projectURL
            currentProjectId = restoredDraftMeeting.projectId
            currentProjectName = restoredDraftMeeting.projectName
            currentVaultURL = preservedDraftContext.vaultURL
            currentDbQueue = preservedDraftContext.dbQueue
            setupNoteAutoSave()
        }
    }

    // MARK: - Recording Control

    /// 新規文字起こしで録音を開始する。
    func startListening(
        dbQueue: DatabaseQueue,
        projectURL: URL?,
        vaultId: UUID,
        projectId: UUID?,
        projectName: String? = nil,
        vaultURL: URL,
        initialMeetingName: String = "",
        usesDraftMeeting: Bool = true,
        recordingTrigger: UsageTelemetryEvent.RecordingTrigger? = nil,
        appendingTo existingMeetingId: UUID? = nil,
        reservation: RecordingStartReservation? = nil
    ) async {
        let startReservation: RecordingStartReservation
        if let reservation {
            guard activeRecordingStartReservation == reservation else { return }
            startReservation = reservation
        } else {
            guard let reservation = reserveRecordingStart() else { return }
            startReservation = reservation
        }
        defer { releaseRecordingStart(startReservation) }
        guard await retryFailedPersistenceIfNeeded() else { return }
        await refreshDefaultInputDevice()
        guard recordingLifecycle == .idle,
              !isFinalizingRecording,
              !isTerminationRequested,
              canStartRecording() else { return }
        await searchIndexer?.pauseForRecording()
        let previousBatchTranscriptionState = batchTranscriptionState
        let activeDraftMeeting = usesDraftMeeting ? draftMeeting : nil
        let preservedDraftContext: PreservedDraftContext? = if !usesDraftMeeting, let draftMeeting {
            PreservedDraftContext(
                meeting: draftMeeting,
                vaultURL: currentVaultURL,
                dbQueue: currentDbQueue
            )
        } else {
            nil
        }
        if preservedDraftContext != nil {
            noteAutoSaveCancellable?.cancel()
        }

        (currentProjectURL, currentProjectId, currentProjectName) = (projectURL, projectId, projectName)
        (currentVaultURL, currentDbQueue) = (vaultURL, dbQueue)
        resetSummaryState()

        let recordingSessionId = UUID.v7()
        let rollbackState = RecordingStartRollbackState(
            segments: store.segments,
            recordingSessions: store.recordingSessions,
            recordingStartTime: store.recordingStartTime,
            preservedDraftContext: preservedDraftContext
        )
        var meetingScope: UsageTelemetryEvent.MeetingScope = rollbackState.recordingSessions.isEmpty ? .new : .continued
        startingMicrophoneSelection = microphoneSelection
        startingSystemAudioEnabled = isSystemAudioEnabled
        startingTranscriptionLocaleIdentifier = transcriptionLocale
        startingLiveSubtitleLocaleIdentifier = liveSubtitleLocale
        recordingLifecycle = .starting(recordingSessionId)
        activeRecordingTelemetryContext = nil
        pendingRealtimeRecognitionFailure = nil
        pendingLiveSubtitleWarning = nil
        let transcriptionMode = AppSettings.shared.transcriptionMode
        let retainAudioAfterBatch = transcriptionMode == .batch
            && AppSettings.shared.retainAudioAfterBatchTranscription
        var transcriptionPlan = TranscriptionSessionPlan(
            finalMode: transcriptionMode,
            liveSubtitlesEnabled: AppSettings.shared.liveSubtitleOverlayEnabled,
            liveChatEnabled: isChatLiveModeEnabled,
            retainBatchAudio: retainAudioAfterBatch
        )
        let finalTranscriptionLocale = resolvedTranscriptionLocale()
        let liveRecognitionLocale = resolvedLiveRecognitionLocale(mode: transcriptionMode)
        activeTranscriptionMode = transcriptionMode
        activeTranscriptionPlan = transcriptionPlan
        activeRecordingSessionId = recordingSessionId
        setActiveControllerSources([])
        if transcriptionPlan.liveSubtitlesEnabled {
            liveCaptionStore.start(sessionId: recordingSessionId)
        } else {
            liveCaptionStore.clear()
        }

        do {
            let batchSampleRate = batchRecordingSampleRate(for: transcriptionPlan)
            transcriptionPlan = try await reconcileStartingPlan(
                transcriptionPlan,
                recordingSessionId: recordingSessionId
            )
            activeTranscriptionPlan = transcriptionPlan
            try ensureSessionIsActive(recordingSessionId)

            let recordingStartTime = Date.now
            prepareRecordingStart(
                existingMeetingId: existingMeetingId,
                recordingStartTime: recordingStartTime
            )

            try await startPersistence(
                PersistenceStartRequest(
                    dbQueue: dbQueue,
                    vaultId: vaultId,
                    projectId: projectId,
                    existingMeetingId: existingMeetingId,
                    recordingStartTime: recordingStartTime,
                    recordingSessionId: recordingSessionId,
                    transcriptionMode: transcriptionMode,
                    persistencePolicy: transcriptionPlan.persistsRealtimeTranscript ? .streaming : .deferred,
                    retainAudioAfterBatch: retainAudioAfterBatch,
                    draftMeeting: activeDraftMeeting,
                    initialMeetingName: initialMeetingName
                )
            )
            meetingScope = persistenceService?.isFirstRecordingSession == true ? .new : .continued
            try await prepareAndStartRecordingController(RecordingControllerStartRequest(
                dbQueue: dbQueue,
                meetingId: currentMeetingId,
                sessionId: recordingSessionId,
                startedAt: recordingStartTime,
                plan: transcriptionPlan,
                transcriptionLocale: finalTranscriptionLocale,
                liveRecognitionLocale: liveRecognitionLocale,
                batchSampleRate: batchSampleRate
            ))

            transcriptionPlan = try await reconcileStartingLiveConfiguration(
                transcriptionPlan,
                recordingSessionId: recordingSessionId
            )
            await transcriptionEventPipeline?.flushUI()
            try ensureSessionIsActive(recordingSessionId)

            if let failure = pendingRealtimeRecognitionFailure {
                throw RecordingPipelineFailure(message: failure.message)
            }

            completePersistenceStart(
                existingMeetingId: existingMeetingId,
                activeDraftMeeting: activeDraftMeeting
            )
            markRecordingStarted(recordingSessionId: recordingSessionId)
            let mode = UsageTelemetryEvent.TranscriptionModeValue(transcriptionMode)
            if let sources = UsageTelemetryEvent.AudioSources(sources: activeControllerSources) {
                activeRecordingTelemetryContext = RecordingTelemetryContext(
                    mode: mode,
                    audioSources: sources,
                    meetingScope: meetingScope,
                    trigger: recordingTrigger
                )
                usageTelemetryReporter(.recording(
                    .started,
                    mode: mode,
                    sources: sources,
                    meetingScope: meetingScope,
                    duration: nil,
                    trigger: recordingTrigger
                ))
                if transcriptionMode == .realtime {
                    usageTelemetryReporter(.transcription(.started, mode: mode))
                }
            }
            if existingMeetingId == nil,
               let event = activeDraftMeeting?.linkedCalendarEvent,
               let meetingId = currentMeetingId {
                CustomerIntelligenceIngestionService.schedule(
                    calendarEvent: event,
                    meetingId: meetingId,
                    vaultId: vaultId,
                    observedAt: recordingStartTime,
                    dbQueue: dbQueue
                )
            }
            pendingRealtimeRecognitionFailure = nil
        } catch {
            await handleRecordingStartFailure(
                error,
                recordingSessionId: recordingSessionId,
                rollbackState: rollbackState,
                existingMeetingId: existingMeetingId,
                meetingScope: meetingScope,
                previousBatchTranscriptionState: previousBatchTranscriptionState
            )
            await searchIndexer?.start()
        }
    }

    func reserveRecordingStart() -> RecordingStartReservation? {
        guard recordingLifecycle == .idle,
              !isRecordingStartPending,
              !isFinalizingRecording,
              !isTerminationRequested,
              !AppDelegate.isBackupRestorePreparationActive else { return nil }
        let reservation = RecordingStartReservation(id: .v7())
        activeRecordingStartReservation = reservation
        isRecordingStartPending = true
        return reservation
    }

    private func releaseRecordingStart(_ reservation: RecordingStartReservation) {
        guard activeRecordingStartReservation == reservation else { return }
        activeRecordingStartReservation = nil
        isRecordingStartPending = false
    }

    func stopListening() {
        guard case let .recording(activeSessionId) = recordingLifecycle,
              isListening,
              !isFinalizingRecording else { return }

        recordingLifecycle = .stopping(activeSessionId)
        recordingAudioLevelStore.reset()
        finalizingMeetingId = recordingMeetingId
        isFinalizingRecording = true
        let automaticScreenshotStopTask = stopAutomaticScreenshotCapture()
        let configurationTasks = Array(recordingConfigurationTasks.values)
        configurationTasks.forEach { $0.cancel() }
        recordingConfigurationTasks.removeAll()
        isListening = false

        // ナビゲーション済みの場合、録音コンテキストからデータを取得
        let ctx = recordingContext
        let activeStore = ctx?.store ?? store
        let stopContext = RecordingStopContext(
            configurationTasks: configurationTasks,
            automaticScreenshotStopTask: automaticScreenshotStopTask,
            store: activeStore,
            meetingId: ctx?.meetingId ?? currentMeetingId,
            projectName: ctx?.projectName ?? selectedProjectName,
            vaultURL: ctx?.vaultURL ?? currentVaultURL,
            dbQueue: ctx?.dbQueue ?? currentDbQueue,
            recordingStart: activeStore.timeBase,
            transcriptionMode: activeTranscriptionMode ?? .realtime,
            telemetry: activeRecordingTelemetryContext,
            recordingSessionId: persistenceService?.recordingSessionId
        )

        recordingStopTask = Task { [weak self] in
            guard let self else { return }
            await self.finishRecordingStop(stopContext)
            self.recordingStopTask = nil
        }
    }

    private func finishRecordingStop(_ context: RecordingStopContext) async {
        var stopResult: RecordingSessionController.StopResult?
        var firstFailureMessage: String?
        var recordingFailureStage = context.telemetry?.recordingFailureStage
        var transcriptionFailureStage = context.telemetry?.transcriptionFailureStage
        do {
            stopResult = try await recordingSessionController.stop()
            if context.transcriptionMode != .batch {
                firstFailureMessage = stopResult?.captureFailureMessage
            }
            if stopResult?.captureFailureMessage != nil {
                recordingFailureStage = recordingFailureStage ?? .capture
                if context.transcriptionMode == .realtime {
                    transcriptionFailureStage = transcriptionFailureStage ?? .transcription
                }
            }
            if context.transcriptionMode == .batch, stopResult?.batchRecordingSucceeded != true {
                recordingFailureStage = recordingFailureStage ?? .persistence
            }
        } catch {
            firstFailureMessage = error.localizedDescription
            recordingFailureStage = recordingFailureStage ?? .stop
            if context.transcriptionMode == .realtime {
                transcriptionFailureStage = transcriptionFailureStage ?? .transcription
            }
            ErrorReportingService.capture(error, context: ["source": "stopRecordingSession"])
            await recordingSessionController.abort()
        }
        for task in context.configurationTasks {
            await task.value
        }
        let stoppingPipeline = transcriptionEventPipeline
        let stoppingLiveCaptionEventRelay = liveCaptionEventRelay
        let stoppingLiveTranscriptRelay = liveTranscriptRelay
        if let stoppingPipeline {
            do {
                try await stoppingPipeline.finish()
            } catch {
                firstFailureMessage = firstFailureMessage ?? error.localizedDescription
                recordingFailureStage = recordingFailureStage ?? .persistence
                transcriptionFailureStage = transcriptionFailureStage ?? .persistence
                ErrorReportingService.capture(error, context: ["source": "stopTranscriptionPersistence"])
            }
        }
        await stoppingLiveCaptionEventRelay?.finish()
        await stoppingLiveTranscriptRelay?.finish()
        transcriptionEventPipeline = nil
        liveCaptionEventRelay = nil
        liveTranscriptRelay = nil
        let stoppingPersistenceService = persistenceService
        let persistenceResult = await stoppingPersistenceService?.stop()
            ?? .failure(message: L10n.recordingSessionNotActive)
        if persistenceResult.succeeded {
            await stoppingPipeline?.notifyPersistenceRecoveredAfterFinish()
        }
        await context.automaticScreenshotStopTask.value
        failedPersistenceService = persistenceResult.succeeded ? nil : stoppingPersistenceService
        failedPersistenceMeetingId = persistenceResult.succeeded ? nil : stoppingPersistenceService?.meetingId
        failedTranscriptionEventPipeline = persistenceResult.succeeded ? nil : stoppingPipeline
        if !persistenceResult.succeeded {
            recordingFailureStage = recordingFailureStage ?? .persistence
            if context.transcriptionMode == .realtime {
                transcriptionFailureStage = transcriptionFailureStage ?? .persistence
            }
        }
        persistenceService = nil
        recordingContext = nil
        if persistenceResult.succeeded, let meetingId = context.meetingId {
            conversationMetricsStore.invalidate(meetingId: meetingId)
        }
        firstFailureMessage = firstFailureMessage ?? persistenceResult.failureMessage
        if let firstFailureMessage {
            errorMessage = firstFailureMessage
        }
        await recordingSessionController.completeStop()
        activeTranscriptionMode = nil
        activeTranscriptionPlan = nil
        activeRecordingSessionId = nil
        activeRecordingTelemetryContext = nil
        setActiveControllerSources([])
        pendingRealtimeRecognitionFailure = nil
        pendingLiveSubtitleWarning = nil
        startingMicrophoneSelection = nil
        startingSystemAudioEnabled = nil
        startingTranscriptionLocaleIdentifier = nil
        startingLiveSubtitleLocaleIdentifier = nil
        liveCaptionStore.clear()
        recordingLifecycle = .idle
        if !isTerminationRequested {
            await searchIndexer?.start()
        }
        var segments = context.store.segments
        let recordingSessions = context.store.recordingSessions
        isFinalizingRecording = false
        finalizingMeetingId = nil

        if var telemetry = context.telemetry {
            telemetry.recordingFailureStage = recordingFailureStage
            telemetry.transcriptionFailureStage = transcriptionFailureStage
            let recordingSession = context.recordingSessionId.flatMap { sessionID in
                context.store.recordingSessions.first { $0.id == sessionID }
            }
            let recordingDuration = recordingSession.flatMap { session in
                session.endedAt.map { max(0, $0.timeIntervalSince(session.startedAt)) }
            }
            telemetry.terminalEvents(recordingDuration: recordingDuration).forEach(usageTelemetryReporter)
        }

        if context.transcriptionMode == .batch, let recordingSessionId = context.recordingSessionId {
            await finishStoppedBatchRecording(
                recordingSessionId: recordingSessionId,
                stopResult: stopResult,
                persistenceResult: persistenceResult,
                meetingId: context.meetingId,
                vaultURL: context.vaultURL,
                dbQueue: context.dbQueue
            )
            return
        }

        if let meetingId = context.meetingId, let dbQueue = context.dbQueue {
            segments = await mergedSegmentsForExport(
                meetingId: meetingId,
                dbQueue: dbQueue,
                activeSegments: segments
            )
            if currentMeetingId == meetingId {
                currentMeetingHasTranscriptSegments = !segments.isEmpty
            }
        }
        guard let vaultURL = context.vaultURL,
              let meetingId = context.meetingId,
              !segments.isEmpty else { return }
        await exportFiles(
            vaultURL: vaultURL,
            meetingId: meetingId,
            projectName: context.projectName ?? "",
            createdAt: context.recordingStart,
            segments: segments,
            recordingSessions: recordingSessions
        )
    }

    private func requestedTelemetryAudioSources() -> UsageTelemetryEvent.AudioSources? {
        var sources: Set<RecordingAudioSource> = []
        if selectedMicrophoneID != nil { sources.insert(.microphone) }
        if startingSystemAudioEnabled ?? isSystemAudioEnabled { sources.insert(.system) }
        return UsageTelemetryEvent.AudioSources(sources: sources)
    }

    private func retryFailedPersistenceIfNeeded() async -> Bool {
        guard let failedPersistenceService else { return true }
        let meetingId = failedPersistenceService.meetingId
        let result = await failedPersistenceService.stop()
        guard result.succeeded else {
            errorMessage = result.failureMessage
            return false
        }
        await failedTranscriptionEventPipeline?.notifyPersistenceRecoveredAfterFinish()
        self.failedPersistenceService = nil
        failedPersistenceMeetingId = nil
        failedTranscriptionEventPipeline = nil
        conversationMetricsStore.invalidate(meetingId: meetingId)
        return true
    }

    /// Shares one persistence recovery attempt across concurrently starting summary jobs.
    private func recoverFailedPersistenceForSummary() async -> String? {
        if let summaryPersistenceRecoveryTask {
            return await summaryPersistenceRecoveryTask.value
        }
        guard let failedPersistenceService else { return nil }
        let meetingId = failedPersistenceService.meetingId
        let failedTranscriptionEventPipeline = failedTranscriptionEventPipeline
        let recoveryTask = Task { () -> String? in
            let result = await failedPersistenceService.stop()
            guard result.succeeded else {
                return result.failureMessage ?? L10n.summaryGenerationFailed
            }
            await failedTranscriptionEventPipeline?.notifyPersistenceRecoveredAfterFinish()
            return nil
        }
        summaryPersistenceRecoveryTask = recoveryTask
        let failureMessage = await recoveryTask.value
        summaryPersistenceRecoveryTask = nil
        if failureMessage == nil {
            self.failedPersistenceService = nil
            failedPersistenceMeetingId = nil
            self.failedTranscriptionEventPipeline = nil
            conversationMetricsStore.invalidate(meetingId: meetingId)
        }
        return failureMessage
    }

    private func finishStoppedBatchRecording(
        recordingSessionId: UUID,
        stopResult: RecordingSessionController.StopResult?,
        persistenceResult: MeetingPersistenceStopResult,
        meetingId: UUID?,
        vaultURL: URL?,
        dbQueue: DatabaseQueue?
    ) async {
        if let failureMessage = Self.stoppedBatchRecordingFailureMessage(
            stopResult: stopResult,
            persistenceResult: persistenceResult
        ) {
            if currentMeetingId == meetingId {
                batchTranscriptionState = .failed(
                    sessionId: recordingSessionId,
                    message: failureMessage
                )
            }
        } else if let meetingId {
            if currentMeetingId == meetingId {
                batchTranscriptionState = .awaitingConfirmation(sessionId: recordingSessionId)
            }
            presentBatchTranscriptionConfirmation(
                sessionId: recordingSessionId,
                meetingId: meetingId,
                suggestedLocaleIdentifier: transcriptionLocale,
                dbQueue: dbQueue,
                vaultURL: vaultURL
            )
        }
        await completeBatchRecording(
            meetingId: meetingId,
            vaultURL: vaultURL,
            dbQueue: dbQueue
        )
    }

    static func stoppedBatchRecordingFailureMessage(
        stopResult: RecordingSessionController.StopResult?,
        persistenceResult: MeetingPersistenceStopResult
    ) -> String? {
        let recordingFailed = stopResult?.batchRecordingSucceeded != true
            || stopResult?.captureFailureMessage != nil
            || !persistenceResult.succeeded
        guard recordingFailed else { return nil }
        return stopResult?.batchFailureMessage
            ?? stopResult?.captureFailureMessage
            ?? persistenceResult.failureMessage.map(L10n.batchAudioWriteFailed)
            ?? L10n.batchAudioWriteFailed("")
    }

    private func presentBatchTranscriptionConfirmation(
        sessionId: UUID,
        meetingId: UUID,
        suggestedLocaleIdentifier: String,
        dbQueue: DatabaseQueue?,
        vaultURL: URL?
    ) {
        let details = makeBatchTranscriptionConfirmationDetails(
            meetingId: meetingId,
            dbQueue: dbQueue
        )
        if let dbQueue, let vaultURL {
            batchSummaryContextsBySessionId[sessionId] = BatchSummaryContext(
                dbQueue: dbQueue,
                vaultURL: vaultURL,
                meetingName: details.meetingName
            )
        }
        let preferences = batchConfirmationPreferences(
            sessionId: sessionId,
            suggestedLocaleIdentifier: suggestedLocaleIdentifier,
            dbQueue: dbQueue
        )
        pendingBatchTranscriptionConfirmation = BatchTranscriptionConfirmation(
            sessionId: sessionId,
            meetingId: meetingId,
            suggestedLocaleIdentifier: preferences.localeIdentifier,
            retainAudioAfterBatch: preferences.retainsAudio,
            initialLanguageSelection: preferences.languageSelection,
            automaticLanguageCandidateSnapshot: preferences.automaticLanguageCandidateSnapshot,
            initiallyGeneratesSummary: AppSettings.shared.generateSummaryAfterBatchTranscription,
            projectSelection: details.projectSelection
        )
        MainWindowOpener.shared.openMainWindow()
    }

    private func batchConfirmationPreferences(
        sessionId: UUID,
        suggestedLocaleIdentifier: String,
        dbQueue: DatabaseQueue?,
        confirmationSessionIds: [UUID]? = nil
    ) -> (
        localeIdentifier: String,
        retainsAudio: Bool,
        languageSelection: BatchTranscriptionLanguageSelection,
        automaticLanguageCandidateSnapshot: BatchLanguageDetectionCandidateSnapshot?
    ) {
        let fallbackRetention = AppSettings.shared.retainAudioAfterBatchTranscription
        guard let dbQueue,
              let stored = try? dbQueue.read({ db -> (RecordingSessionRecord?, String?, Int) in
                  let session = try RecordingSessionRecord.fetchOne(db, key: sessionId)
                  let localeIdentifier = try String.fetchOne(
                      db,
                      sql: """
                      SELECT ranges.localeIdentifier
                      FROM recording_audio_segment_ranges AS ranges
                      JOIN recording_audio_segments AS segments ON segments.id = ranges.audioSegmentId
                      WHERE segments.recordingSessionId = ?
                      ORDER BY segments.segmentIndex, ranges.startFrame
                      LIMIT 1
                      """,
                      arguments: [sessionId]
                  )
                  guard let session else { return (nil, localeIdentifier, 0) }
                  let localeCount: Int
                  if let confirmationSessionIds, !confirmationSessionIds.isEmpty {
                      let placeholders = Array(repeating: "?", count: confirmationSessionIds.count).joined(separator: ",")
                      localeCount = try Int.fetchOne(
                          db,
                          sql: """
                          SELECT COUNT(DISTINCT ranges.localeIdentifier)
                          FROM recording_audio_segment_ranges AS ranges
                          JOIN recording_audio_segments AS segments ON segments.id = ranges.audioSegmentId
                          WHERE segments.recordingSessionId IN (\(placeholders))
                          """,
                          arguments: StatementArguments(confirmationSessionIds)
                      ) ?? 0
                  } else {
                      let confirmsOnlySelectedSession = session.batchLastError?.nilIfBlank != nil
                      localeCount = try Int.fetchOne(
                          db,
                          sql: """
                          SELECT COUNT(DISTINCT ranges.localeIdentifier)
                          FROM recording_audio_segment_ranges AS ranges
                          JOIN recording_audio_segments AS segments ON segments.id = ranges.audioSegmentId
                          JOIN recording_sessions AS sessions ON sessions.id = segments.recordingSessionId
                          WHERE segments.recordingSessionId = ?
                             OR (? = 0
                                 AND sessions.meetingId = ?
                                 AND sessions.transcriptionMode = ?
                                 AND sessions.endedAt IS NOT NULL
                                 AND sessions.batchCompletedAt IS NULL
                                 AND sessions.batchDiscardedAt IS NULL
                                 AND sessions.batchLastError IS NULL
                                 AND sessions.batchLastAttemptAt IS NULL
                                 AND sessions.batchAttemptCount = 0)
                          """,
                          arguments: [
                              sessionId,
                              confirmsOnlySelectedSession ? 1 : 0,
                              session.meetingId,
                              TranscriptionMode.batch.rawValue,
                          ]
                      ) ?? 0
                  }
                  return (session, localeIdentifier, localeCount)
              }),
              let session = stored.0 else {
            return (
                suggestedLocaleIdentifier,
                fallbackRetention,
                .manual(localeIdentifier: suggestedLocaleIdentifier),
                nil
            )
        }
        let localeIdentifier = session.batchSelectedLocaleIdentifier ?? stored.1 ?? suggestedLocaleIdentifier
        let preservesStoredSelection = session.batchCompletedAt != nil
            || (session.batchLastError?.nilIfBlank != nil && session.batchAttemptCount > 0)
        let languageSelection: BatchTranscriptionLanguageSelection = if preservesStoredSelection,
                                                                        session.batchLanguageDetectionMode == .automatic {
            .automatic
        } else if stored.2 > 1 {
            .recorded
        } else {
            .manual(localeIdentifier: localeIdentifier)
        }
        let automaticLanguageCandidateSnapshot = session.batchAutomaticLanguageCandidatesJSON
            .flatMap { try? BatchLanguageDetectionCandidateSnapshot.decode($0) }
        return (localeIdentifier, session.retainAudioAfterBatch, languageSelection, automaticLanguageCandidateSnapshot)
    }

    private nonisolated static func pendingBatchRetranscriptionSessionIds(
        meetingId: UUID,
        dbQueue: DatabaseQueue
    ) async -> [UUID]? {
        try? await dbQueue.read { db in
            try RecordingSessionRecord
                .filter(Column("meetingId") == meetingId)
                .filter(Column("batchCompletedAt") != nil)
                .filter(sql: "batchLastAttemptAt > batchCompletedAt")
                .order(Column("startedAt").asc)
                .fetchAll(db)
                .map(\.id)
        }
    }

    private func completeBatchRecording(
        meetingId: UUID?,
        vaultURL: URL?,
        dbQueue: DatabaseQueue?
    ) async {
        if let vaultURL, let meetingId, let dbQueue {
            await exportBatchScreenshots(
                vaultURL: vaultURL,
                meetingId: meetingId,
                dbQueue: dbQueue
            )
        }
    }

    private func exportBatchScreenshots(vaultURL: URL, meetingId: UUID, dbQueue: DatabaseQueue) async {
        let screenshots = await Task.detached(priority: .utility) {
            let repository = MeetingRepository(dbQueue: dbQueue)
            return (try? repository.fetchScreenshots(forMeetingId: meetingId)) ?? []
        }.value
        guard !screenshots.isEmpty else { return }
        _ = await Task.detached(priority: .utility) {
            try? ScreenshotExportService.exportScreenshots(
                vaultURL: vaultURL,
                screenshots: screenshots
            )
        }.value
    }

    private func mergedSegmentsForExport(
        meetingId: UUID,
        dbQueue: DatabaseQueue,
        activeSegments: [TranscriptSegment]
    ) async -> [TranscriptSegment] {
        let persistedSegments = await (try? dbQueue.read { db in
            try TranscriptSegmentRecord
                .filter(Column("meetingId") == meetingId)
                .order(Column("startTime").asc)
                .fetchAll(db)
                .map(TranscriptSegment.init(from:))
        }) ?? []
        var segmentsById = Dictionary(uniqueKeysWithValues: persistedSegments.map { ($0.id, $0) })
        for segment in activeSegments {
            segmentsById[segment.id] = segment
        }
        return segmentsById.values.sorted { lhs, rhs in
            if lhs.startTime == rhs.startTime {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.startTime < rhs.startTime
        }
    }

    /// 現在選択中のプロジェクト名。
    private var selectedProjectName: String? {
        currentProjectName ?? currentProjectURL?.lastPathComponent
    }

    private struct SummaryGenerationRequest {
        let meetingId: UUID
        let meetingName: String
        let dbQueue: DatabaseQueue
        let projectURL: URL?
        let projectName: String
        let projectDescription: String?
        let recordingStartedAt: Date
        let vaultURL: URL
        let noteText: String?
        let recordingSessions: [RecordingSessionTimeline]
        let options: SummaryGenerationOptions
        let generationSettings: SummaryGenerationSettings
        let retriesFailedPersistence: Bool
        let telemetryTrigger: UsageTelemetryEvent.SummaryTrigger
    }

    private struct BatchSummaryContext {
        let dbQueue: DatabaseQueue
        let vaultURL: URL
        let meetingName: String
    }

    private final class PendingBatchSummaryRequest {
        let meetingId: UUID
        let options: SummaryGenerationOptions
        let dbQueue: DatabaseQueue
        let vaultURL: URL
        let job: SummaryGenerationJob
        var sessionIDs: Set<UUID>
        var completedSessionIDs: Set<UUID> = []
        var transcriptionProgressBySessionID: [UUID: Double] = [:]

        init(
            sessionID: UUID,
            meetingId: UUID,
            options: SummaryGenerationOptions,
            dbQueue: DatabaseQueue,
            vaultURL: URL,
            job: SummaryGenerationJob
        ) {
            self.meetingId = meetingId
            self.options = options
            self.dbQueue = dbQueue
            self.vaultURL = vaultURL
            self.job = job
            sessionIDs = [sessionID]
        }

        var isTranscriptionCompleted: Bool {
            sessionIDs.isSubset(of: completedSessionIDs)
        }

        var transcriptionProgress: Double {
            guard !sessionIDs.isEmpty else { return 0 }
            let completedProgress = sessionIDs.reduce(0.0) { partialResult, sessionID in
                partialResult + (transcriptionProgressBySessionID[sessionID] ?? 0)
            }
            return completedProgress / Double(sessionIDs.count)
        }

        var sortKey: String {
            sessionIDs.map(\.uuidString).min() ?? ""
        }

        func hasSamePersistenceContext(as other: PendingBatchSummaryRequest) -> Bool {
            dbQueue === other.dbQueue
                && vaultURL.standardizedFileURL == other.vaultURL.standardizedFileURL
        }
    }

    private enum SummaryGenerationPreparationError: LocalizedError {
        case meetingUnavailable
        case emptyTranscript

        var errorDescription: String? {
            switch self {
            case .meetingUnavailable: L10n.meetingUnavailable
            case .emptyTranscript: L10n.transcriptEmpty
            }
        }
    }

    // MARK: - Summary Generation

    private var canStartManualSummaryGeneration: Bool {
        !isListening && !isFinalizingRecording && !isDeletingScreenshots
    }

    /// 手動で要約を実行できるかどうか。
    var canGenerateSummary: Bool {
        guard canStartManualSummaryGeneration,
              let currentMeetingId,
              !isSummaryGenerating(meetingId: currentMeetingId),
              currentVaultURL != nil,
              batchTranscriptionState?.blocksSummaryGeneration != true else { return false }
        return currentMeetingHasTranscriptSegments
    }

    func canRegenerateSummaries(meetingIds: Set<UUID>) -> Bool {
        canStartManualSummaryGeneration
            && meetingIds.contains { !isSummaryGenerating(meetingId: $0) }
    }

    func isSummaryGenerating(meetingId: UUID) -> Bool {
        summaryGeneratingMeetingIDs.contains(meetingId)
    }

    #if DEBUG
        func registerPendingBatchSummaryForTesting(
            sessionID: UUID,
            meetingID: UUID,
            options: SummaryGenerationOptions,
            dbQueue: DatabaseQueue,
            vaultURL: URL
        ) {
            let meetingName = (try? MeetingRepository(dbQueue: dbQueue).fetchMeeting(id: meetingID)?.name.nilIfBlank)
                ?? L10n.newMeeting
            let job = makeBatchSummaryGenerationJob(
                meetingID: meetingID,
                options: options,
                meetingName: meetingName
            )
            pendingBatchSummaryRequestsBySessionId[sessionID] = PendingBatchSummaryRequest(
                sessionID: sessionID,
                meetingId: meetingID,
                options: options,
                dbQueue: dbQueue,
                vaultURL: vaultURL,
                job: job
            )
            summaryGenerationJobs.append(job)
        }

        func registerConfirmedBatchSummarySessionsForTesting(
            anchorSessionID: UUID,
            sessionIDs: [UUID]
        ) {
            guard let request = pendingBatchSummaryRequestsBySessionId[anchorSessionID] else { return }
            registerConfirmedBatchSummarySessions(
                anchorSessionID: anchorSessionID,
                result: BatchTranscriptionConfirmationService.Result(
                    meetingId: request.meetingId,
                    sessionIds: sessionIDs
                )
            )
        }

        func confirmPendingBatchSummaryForTesting(
            sessionID: UUID,
            meetingID: UUID,
            options: SummaryGenerationOptions
        ) {
            updatePendingBatchSummaryRequest(
                sessionID: sessionID,
                meetingID: meetingID,
                options: options
            )
            batchSummaryContextsBySessionId.removeValue(forKey: sessionID)
        }

        var completedBatchSummarySessionCountForTesting: Int {
            Set(pendingBatchSummaryRequestsBySessionId.values.flatMap(\.completedSessionIDs)).count
        }

        func setScreenshotDeletionInProgressForTesting(_ isInProgress: Bool) {
            isDeletingScreenshots = isInProgress
        }
    #endif

    func dismissSummaryGenerationJob(_ jobID: UUID) {
        guard let job = summaryGenerationJobs.first(where: { $0.id == jobID }),
              job.hasFailure,
              job.isFinished else { return }
        summaryGenerationJobs.removeAll { $0.id == jobID }
        let hasRemainingFailure = summaryGenerationJobs.contains { $0.meetingId == job.meetingId && $0.hasFailure }
        if !hasRemainingFailure, !isSummaryGenerating(meetingId: job.meetingId) {
            summaryErrorsByMeetingId.removeValue(forKey: job.meetingId)
            googleDocsExportErrorsByMeetingId.removeValue(forKey: job.meetingId)
        }
    }

    /// 確認画面で選択した設定を使って手動要約を実行する。
    @discardableResult
    func triggerManualSummary(options: SummaryGenerationOptions = .manual) -> Bool {
        triggerSummary(options: options)
    }

    /// DB に保存済みの複数ミーティングを、現在の画面選択を変更せず個別ジョブとして再生成する。
    func triggerManualSummaries(
        meetingIds: Set<UUID>,
        dbQueue: DatabaseQueue?,
        vaultURL: URL?,
        options: SummaryGenerationOptions = .manual
    ) {
        guard canStartManualSummaryGeneration,
              let dbQueue,
              let vaultURL else { return }

        for meetingId in meetingIds.sorted(by: { $0.uuidString < $1.uuidString })
            where !isSummaryGenerating(meetingId: meetingId) {
            do {
                let request = try makePersistedSummaryRequest(
                    meetingId: meetingId,
                    dbQueue: dbQueue,
                    vaultURL: vaultURL,
                    options: options,
                    telemetryTrigger: .manual
                )
                startSummaryGeneration(request)
            } catch {
                recordSummaryPreparationFailure(
                    error.localizedDescription,
                    meetingId: meetingId,
                    dbQueue: dbQueue
                )
            }
        }
    }

    private func triggerSummary(options: SummaryGenerationOptions) -> Bool {
        guard canGenerateSummary,
              let meetingId = currentMeetingId,
              let vaultURL = currentVaultURL,
              let dbQueue = currentDbQueue else { return false }
        saveNoteImmediately()
        let repo = MeetingRepository(dbQueue: dbQueue)
        let meetingName = (try? repo.fetchMeeting(id: meetingId)?.name.nilIfBlank)
            ?? L10n.newMeeting
        let project = try? currentProjectId.flatMap(repo.fetchProject(id:))
        let request = SummaryGenerationRequest(
            meetingId: meetingId,
            meetingName: meetingName,
            dbQueue: dbQueue,
            projectURL: currentProjectURL,
            projectName: project?.path ?? selectedProjectName ?? "",
            projectDescription: project?.description,
            recordingStartedAt: store.timeBase,
            vaultURL: vaultURL,
            noteText: noteText.nilIfBlank,
            recordingSessions: store.recordingSessions,
            options: options,
            generationSettings: .current(),
            retriesFailedPersistence: true,
            telemetryTrigger: .manual
        )
        requestShowSummaryTab = true
        return startSummaryGeneration(request)
    }

    private func generatePendingBatchSummaryIfReady(meetingId: UUID) {
        guard !isDeletingScreenshots,
              !isSummaryGenerating(meetingId: meetingId) else { return }
        var seenJobIDs: Set<UUID> = []
        let completedRequests = pendingBatchSummaryRequestsBySessionId.values.filter { request in
            seenJobIDs.insert(request.job.id).inserted
                && request.meetingId == meetingId
                && request.isTranscriptionCompleted
                && !request.job.hasFailure
        }
        .sorted { $0.sortKey < $1.sortKey }
        guard let first = completedRequests.first else { return }
        let pendingRequests = completedRequests.filter {
            $0.hasSamePersistenceContext(as: first)
        }
        let options = SummaryGenerationOptions.merging(pendingRequests.map(\.options))
        let job = first.job
        let redundantJobIDs = Set(pendingRequests.map(\.job.id)).subtracting([job.id])
        do {
            let request = try makePersistedSummaryRequest(
                meetingId: meetingId,
                dbQueue: first.dbQueue,
                vaultURL: first.vaultURL,
                options: options,
                telemetryTrigger: .automaticAfterBatch
            )
            removePendingBatchSummaryRequests(pendingRequests)
            summaryGenerationJobs.removeAll { redundantJobIDs.contains($0.id) }
            startSummaryGeneration(request, job: job)
        } catch {
            removePendingBatchSummaryRequests(pendingRequests)
            summaryGenerationJobs.removeAll { redundantJobIDs.contains($0.id) }
            job.progress.summaryGeneration = .failed(error.localizedDescription)
            job.progress.vaultExport = .skipped
            job.progress.googleDocsExport = .skipped
            summaryErrorsByMeetingId[meetingId] = error.localizedDescription
            generatePendingBatchSummaryIfReady(meetingId: meetingId)
        }
    }

    private func generatePendingBatchSummariesIfReady() {
        let meetingIDs = Set(pendingBatchSummaryRequestsBySessionId.values.map(\.meetingId))
        for meetingID in meetingIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            generatePendingBatchSummaryIfReady(meetingId: meetingID)
        }
    }

    private func removePendingBatchSummaryRequests(_ requests: [PendingBatchSummaryRequest]) {
        for request in requests {
            removeSessionAliases(for: request)
        }
    }

    private func removeSessionAliases(for request: PendingBatchSummaryRequest) {
        for sessionID in request.sessionIDs where pendingBatchSummaryRequestsBySessionId[sessionID] === request {
            pendingBatchSummaryRequestsBySessionId.removeValue(forKey: sessionID)
        }
    }

    private func makePersistedSummaryRequest(
        meetingId: UUID,
        dbQueue: DatabaseQueue,
        vaultURL: URL,
        options: SummaryGenerationOptions,
        telemetryTrigger: UsageTelemetryEvent.SummaryTrigger
    ) throws -> SummaryGenerationRequest {
        let snapshot = try dbQueue.read { db in
            let meeting = try MeetingRecord.fetchOne(db, key: meetingId)
            let project = try meeting?.projectId.flatMap { try ProjectRecord.fetchResolved(id: $0, in: db) }
            let note = try MeetingNoteRecord.fetchOne(db, key: meetingId)
            let recordingSessions = try RecordingSessionRecord
                .filter(Column("meetingId") == meetingId)
                .order(Column("offsetSeconds").asc, Column("startedAt").asc)
                .fetchAll(db)
            return (meeting, project, note, recordingSessions)
        }
        guard let meeting = snapshot.0 else { throw SummaryGenerationPreparationError.meetingUnavailable }
        let project = snapshot.1
        return SummaryGenerationRequest(
            meetingId: meetingId,
            meetingName: meeting.name.nilIfBlank ?? L10n.newMeeting,
            dbQueue: dbQueue,
            projectURL: project.map { vaultURL.appending(path: $0.path, directoryHint: .isDirectory) },
            projectName: project?.path ?? "",
            projectDescription: project?.description,
            recordingStartedAt: meeting.effectiveRecordingStartedAt,
            vaultURL: vaultURL,
            noteText: snapshot.2?.text.nilIfBlank,
            recordingSessions: snapshot.3.map(RecordingSessionTimeline.init),
            options: options,
            generationSettings: .current(),
            retriesFailedPersistence: false,
            telemetryTrigger: telemetryTrigger
        )
    }

    private func recordSummaryPreparationFailure(
        _ message: String,
        meetingId: UUID,
        dbQueue: DatabaseQueue
    ) {
        let meetingName = (try? MeetingRepository(dbQueue: dbQueue).fetchMeeting(id: meetingId)?.name.nilIfBlank)
            ?? L10n.newMeeting
        let job = SummaryGenerationJob(meetingId: meetingId, meetingName: meetingName)
        job.progress.summaryGeneration = .failed(message)
        job.progress.vaultExport = .skipped
        job.progress.googleDocsExport = .skipped
        summaryGenerationJobs.append(job)
        summaryErrorsByMeetingId[meetingId] = message
    }

    @discardableResult
    private func startSummaryGeneration(
        _ request: SummaryGenerationRequest,
        job existingJob: SummaryGenerationJob? = nil
    ) -> Bool {
        guard !isSummaryGenerating(meetingId: request.meetingId) else { return false }
        let job = existingJob ?? SummaryGenerationJob(meetingId: request.meetingId, meetingName: request.meetingName)
        job.configureExports(request.options.exportOptions)
        if existingJob == nil {
            summaryGenerationJobs.append(job)
        }
        summaryErrorsByMeetingId.removeValue(forKey: request.meetingId)
        googleDocsExportErrorsByMeetingId.removeValue(forKey: request.meetingId)
        summaryGeneratingMeetingIDs.insert(request.meetingId)
        if currentMeetingId == request.meetingId {
            lastSummaryURL = nil
        }
        usageTelemetryReporter(.summary(.started, trigger: request.telemetryTrigger))

        Task { [weak self] in
            await self?.runSummaryGeneration(request, job: job)
        }
        return true
    }

    private func runSummaryGeneration(_ request: SummaryGenerationRequest, job: SummaryGenerationJob) async {
        defer { finishSummaryGeneration(request, job: job) }

        if request.retriesFailedPersistence {
            if let message = await recoverFailedPersistenceForSummary() {
                failSummaryGeneration(message, request: request, job: job)
                return
            }
        }

        do {
            let summaryInput = try await Task.detached(priority: .userInitiated) {
                try FullTranscriptLoader.summaryInput(
                    meetingId: request.meetingId,
                    dbQueue: request.dbQueue,
                    recordingSessions: request.recordingSessions,
                    timeBase: request.recordingStartedAt
                )
            }.value
            guard !summaryInput.text.isEmpty else { throw SummaryGenerationPreparationError.emptyTranscript }
            try await generateSummary(request: request, summaryInput: summaryInput, job: job)
        } catch {
            failSummaryGeneration(error.localizedDescription, request: request, job: job)
            if Self.shouldCaptureSummaryGenerationError(error) {
                ErrorReportingService.capture(error, context: ["source": "summaryGeneration"])
            }
        }
    }

    // Summary generation coordinates persistence and two optional export destinations as one user operation.
    // swiftlint:disable:next function_body_length
    private func generateSummary(
        request: SummaryGenerationRequest,
        summaryInput: FullTranscriptSummaryInput,
        job: SummaryGenerationJob
    ) async throws {
        let meetingId = request.meetingId
        let repo = MeetingRepository(dbQueue: request.dbQueue)

        let screenshots = (try? repo.fetchScreenshots(forMeetingId: meetingId)) ?? []
        let calendarEvent = try repo.fetchCalendarEvent(forMeetingId: meetingId)
        let promptProjectName = request.projectName.nilIfBlank

        job.progress.summaryGeneration = .running

        let generatedSummary = try await summaryGenerationRunner(SummaryGenerationRunnerInput(
            promptContext: SummaryPromptContext(
                meetingId: meetingId,
                recordedAt: request.recordingStartedAt,
                calendarEvent: calendarEvent,
                projectName: promptProjectName,
                projectDescription: request.projectDescription
            ),
            transcriptText: summaryInput.text,
            noteText: request.noteText,
            screenshots: screenshots,
            recordingSessions: request.recordingSessions,
            generationSettings: request.generationSettings
        ))

        var summaryWasApplied = false
        func markSummaryAsApplied() {
            guard !summaryWasApplied else { return }
            summaryWasApplied = true
            job.progress.summaryGeneration = .completed
            if currentMeetingId == meetingId {
                summaryReloadTask?.cancel()
                summaryReloadTask = nil
                summaryProjectionGeneration &+= 1
                currentSummaryDocument = generatedSummary.document
                currentSummaryGoogleFileId = nil
            }
        }

        func persistGeneratedSummary() throws {
            guard !summaryWasApplied else { return }
            try repo.applyGeneratedSummary(
                toMeetingId: meetingId,
                document: generatedSummary.document,
                tags: generatedSummary.document.tags
            )
            markSummaryAsApplied()
        }

        let exportOptions = request.options.exportOptions
        if exportOptions.exportsToVault {
            usageTelemetryReporter(.export(.started, destination: .vault, trigger: .summaryGeneration))
            job.progress.vaultExport = .running
            do {
                guard let vaultID = try repo.fetchMeeting(id: meetingId)?.vaultId else {
                    throw SummaryGenerationPreparationError.meetingUnavailable
                }
                guard let exportResult = try await VaultSummaryExportService.exportSummary(
                    .init(
                        vaultURL: request.vaultURL,
                        vaultID: vaultID,
                        meetingID: meetingId,
                        dbQueue: request.dbQueue,
                        document: generatedSummary.document,
                        summaryFileName: generatedSummary.fileName,
                        summaryMarkdown: generatedSummary.markdown
                    )
                ) else {
                    throw SummaryGenerationPreparationError.meetingUnavailable
                }
                markSummaryAsApplied()
                try await VaultSummaryExportService.exportSupportingArtifacts(
                    vaultURL: request.vaultURL,
                    meetingId: meetingId,
                    projectName: exportResult.projectName,
                    createdAt: request.recordingStartedAt,
                    segments: summaryInput.segments,
                    recordingSessions: request.recordingSessions,
                    screenshots: screenshots
                )
                job.progress.vaultExport = .completed
                usageTelemetryReporter(.export(.completed, destination: .vault, trigger: .summaryGeneration))
                if currentMeetingId == meetingId { lastSummaryURL = exportResult.fileURL }
            } catch {
                job.progress.vaultExport = .failed(error.localizedDescription)
                summaryErrorsByMeetingId[meetingId] = error.localizedDescription
                ErrorReportingService.capture(error, context: ["source": "vaultSummaryExport"])
                usageTelemetryReporter(.export(.failed(.export), destination: .vault, trigger: .summaryGeneration))
                try persistGeneratedSummary()
            }
        } else {
            try persistGeneratedSummary()
        }

        if exportOptions.exportsToGoogleDocs {
            usageTelemetryReporter(.export(.started, destination: .googleDocs, trigger: .summaryGeneration))
            job.progress.googleDocsExport = .running
            do {
                let fileId = try await exportSummaryToGoogleDocs(
                    document: generatedSummary.document,
                    context: SummaryRenderContext(
                        meetingId: meetingId,
                        createdAt: request.recordingStartedAt,
                        screenshots: screenshots
                    ),
                    fileName: generatedSummary.fileName
                )
                try persistGoogleDocsFileId(
                    fileId,
                    meetingId: meetingId,
                    expectedDocument: generatedSummary.document.databaseJSONString(),
                    dbQueue: request.dbQueue
                )
                job.progress.googleDocsExport = .completed
                usageTelemetryReporter(.export(.completed, destination: .googleDocs, trigger: .summaryGeneration))
            } catch {
                let message = GoogleAuthErrorFormatter.message(
                    for: error,
                    defaultMessage: L10n.googleDocsExportFailed
                )
                job.progress.googleDocsExport = .failed(message)
                googleDocsExportErrorsByMeetingId[meetingId] = message
                ErrorReportingService.captureSanitized(.googleDocsExport)
                usageTelemetryReporter(.export(.failed(.export), destination: .googleDocs, trigger: .summaryGeneration))
            }
        }
    }

    private func failSummaryGeneration(
        _ message: String,
        request: SummaryGenerationRequest,
        job: SummaryGenerationJob
    ) {
        summaryErrorsByMeetingId[request.meetingId] = message
        if currentMeetingId == request.meetingId { requestShowSummaryTab = false }
        job.progress.summaryGeneration = .failed(message)
        job.progress.vaultExport = .skipped
        job.progress.googleDocsExport = .skipped
    }

    private func finishSummaryGeneration(
        _ request: SummaryGenerationRequest,
        job: SummaryGenerationJob
    ) {
        summaryGeneratingMeetingIDs.remove(request.meetingId)
        if job.progress.summaryGeneration.isFailed {
            usageTelemetryReporter(.summary(.failed(.generation), trigger: request.telemetryTrigger))
        } else {
            usageTelemetryReporter(.summary(.completed, trigger: request.telemetryTrigger))
        }
        if !job.hasFailure, job.progress.isAllDone {
            Task { [weak self] in
                guard let self else { return }
                try? await self.summaryJobSleeper(.seconds(2))
                withAnimation(.easeOut(duration: 0.3)) {
                    self.summaryGenerationJobs.removeAll { $0.id == job.id }
                }
            }
        }

        generatePendingBatchSummaryIfReady(meetingId: request.meetingId)
    }

    private func persistGoogleDocsFileId(
        _ fileId: String,
        meetingId: UUID,
        expectedDocument: String,
        dbQueue: DatabaseQueue?
    ) throws {
        let summaryIsCurrent = if let dbQueue {
            try MeetingRepository(dbQueue: dbQueue).updateSummaryGoogleFileId(
                forMeetingId: meetingId,
                googleFileId: fileId,
                expectedDocument: expectedDocument
            )
        } else {
            try currentMeetingId == meetingId
                && currentSummaryDocument?.databaseJSONString() == expectedDocument
        }
        guard summaryIsCurrent else { throw SummaryGoogleDocsExportError.summaryChanged }
        if currentMeetingId == meetingId {
            currentSummaryGoogleFileId = fileId
        }
    }

    private func exportSummaryToGoogleDocs(
        document: SummaryDocument,
        context: SummaryRenderContext,
        fileName: String
    ) async throws -> String {
        await acquireGoogleDocsExport()
        defer { releaseGoogleDocsExport() }
        return try await googleDocsSummaryExporter(document, context, fileName)
    }

    private func acquireGoogleDocsExport() async {
        if !isGoogleDocsExportBusy {
            isGoogleDocsExportBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            googleDocsExportWaiters.append(continuation)
        }
    }

    private func releaseGoogleDocsExport() {
        guard !googleDocsExportWaiters.isEmpty else {
            isGoogleDocsExportBusy = false
            return
        }
        googleDocsExportWaiters.removeFirst().resume()
    }

    nonisolated static func shouldCaptureSummaryGenerationError(_ error: any Error) -> Bool {
        if error is CancellationError { return false }
        if let configurationError = error as? CodexConfigurationError, case .accountNotReady = configurationError { return false }
        guard let error = error as? CodexAppServerError else { return true }
        return switch error {
        case .helperNotBundled, .notLoggedIn, .providerAuthenticationFailed, .requestTimedOut, .turnInterrupted:
            false
        default:
            true
        }
    }

    /// 要約なしでファイル書き出しのみ実行する。
    private func exportFiles(
        vaultURL: URL,
        meetingId: UUID,
        projectName: String,
        createdAt: Date,
        segments: [TranscriptSegment],
        recordingSessions: [RecordingSessionTimeline]
    ) async {
        var screenshots: [MeetingScreenshotRecord] = []
        if let dbQueue = currentDbQueue {
            let repo = MeetingRepository(dbQueue: dbQueue)
            screenshots = (try? repo.fetchScreenshots(forMeetingId: meetingId)) ?? []
        }
        await exportTranscriptAndScreenshots(
            vaultURL: vaultURL,
            meetingId: meetingId,
            projectName: projectName,
            createdAt: createdAt,
            segments: segments,
            recordingSessions: recordingSessions,
            screenshots: screenshots
        )
    }

    /// transcript と screenshot をファイルに書き出す共通処理。メインアクター外で実行。
    private func exportTranscriptAndScreenshots(
        vaultURL: URL,
        meetingId: UUID,
        projectName: String,
        createdAt: Date,
        segments: [TranscriptSegment],
        recordingSessions: [RecordingSessionTimeline],
        screenshots: [MeetingScreenshotRecord]
    ) async {
        async let transcriptPath = Task.detached {
            try? TranscriptExportService.exportTranscript(
                vaultURL: vaultURL,
                meetingId: meetingId,
                projectName: projectName,
                createdAt: createdAt,
                segments: segments,
                recordingSessions: recordingSessions
            )
        }.value

        async let screenshotExport: Void = Task.detached {
            guard !screenshots.isEmpty else { return }
            _ = try? ScreenshotExportService.exportScreenshots(
                vaultURL: vaultURL,
                screenshots: screenshots
            )
        }.value

        _ = await transcriptPath
        _ = await screenshotExport
    }

    // MARK: - Screenshot

    /// キャプチャ対象のウィンドウ一覧を更新する。
    func refreshAvailableWindows() {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                let myBundleID = Bundle.main.bundleIdentifier
                let newWindows = ScreenshotWindowOption.build(
                    from: content.windows.map(ScreenshotWindowOption.Snapshot.init(window:)),
                    excludingBundleID: myBundleID
                )
                if newWindows != self.availableWindows {
                    self.availableWindows = newWindows
                }
                // 選択中のウィンドウが一覧から消えていたら未設定に戻す。
                if case let .window(id) = screenshotCaptureSource,
                   !self.availableWindows.contains(where: { $0.id == id }) {
                    screenshotCaptureSource = .none
                }
            } catch {
                self.availableWindows = []
            }
        }
    }

    private func updateAutomaticScreenshotProcessingSettings() {
        guard isListening,
              AppSettings.shared.automaticScreenshotEnabled,
              screenshotCaptureSource.isSelected else { return }
        let intervalSeconds = AppSettings.shared.automaticScreenshotIntervalSeconds
        let changeThresholdRatio = AppSettings.shared.automaticScreenshotChangeThresholdRatio
        let detectsChangesInSharedContentOnly = AppSettings.shared.automaticScreenshotDetectChangesInSharedRegionOnly
        let cropsToSharedContent = AppSettings.shared.automaticScreenshotCropToSharedRegion
        automaticScreenshotCaptureControl.enqueue { capture in
            await capture.updateSettings(
                intervalSeconds: intervalSeconds,
                changeThresholdRatio: changeThresholdRatio,
                detectsChangesInSharedContentOnly: detectsChangesInSharedContentOnly,
                cropsToSharedContent: cropsToSharedContent
            )
        }
    }

    private func syncAutomaticScreenshotCaptureState() {
        if isListening, AppSettings.shared.automaticScreenshotEnabled, screenshotCaptureSource.isSelected {
            startAutomaticScreenshotCapture()
        } else {
            stopAutomaticScreenshotCapture()
        }
    }

    private func startAutomaticScreenshotCapture() {
        guard isListening,
              AppSettings.shared.automaticScreenshotEnabled,
              screenshotCaptureSource.isSelected,
              let meetingId = activeMeetingIdForSessionControls,
              let dbQueue = activeDbQueueForSessionControls
        else { return }
        let request = AutomaticScreenshotCaptureRequest(
            source: screenshotCaptureSource,
            intervalSeconds: AppSettings.shared.automaticScreenshotIntervalSeconds,
            changeThresholdRatio: AppSettings.shared.automaticScreenshotChangeThresholdRatio,
            detectsChangesInSharedContentOnly: AppSettings.shared.automaticScreenshotDetectChangesInSharedRegionOnly,
            cropsToSharedContent: AppSettings.shared.automaticScreenshotCropToSharedRegion,
            meetingID: meetingId,
            sessionID: persistenceService?.recordingSessionId,
            dbQueue: dbQueue,
            onPersisted: { [weak self] record in
                self?.screenshotStore.upsert(record)
            },
            onFailure: { [weak self] error in
                guard let self, self.isListening else { return }
                self.errorMessage = L10n.screenshotCaptureFailed(error.localizedDescription)
            }
        )
        automaticScreenshotCaptureControl.enqueue { capture in
            await capture.start(request)
        }
    }

    @discardableResult
    private func stopAutomaticScreenshotCapture() -> Task<Void, Never> {
        automaticScreenshotCaptureControl.stop()
    }

    // MARK: - Note Auto-Save

    private func setupNoteAutoSave() {
        noteAutoSaveCancellable?.cancel()
        noteAutoSaveCancellable = $noteText
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] text in
                self?.saveNote(text: text)
            }
    }

    private func resetNoteState() {
        noteText = ""
        hasNote = false
        currentNoteCreatedAt = nil
        lastSavedNoteText = nil
        noteAutoSaveCancellable?.cancel()
    }

    private func saveNote(text: String) {
        if currentMeetingId == nil, hasDraftMeeting, !text.isEmpty {
            _ = materializeDraftMeeting(customerIntelligenceIngestion: .afterMeetingPersistence)
            return
        }
        guard let meetingId = currentMeetingId,
              let dbQueue = currentDbQueue else { return }
        let now = Date()
        let isNew = !hasNote
        let note = MeetingNoteRecord(
            meetingId: meetingId,
            text: text,
            createdAt: isNew ? now : (currentNoteCreatedAt ?? now),
            updatedAt: now
        )
        let repo = MeetingRepository(dbQueue: dbQueue)
        do {
            try repo.upsertNote(note)
            if isNew {
                hasNote = true
                currentNoteCreatedAt = now
            }
            lastSavedNoteText = text
        } catch {
            captionViewModelLogger.error("Failed to save note: \(error)")
        }
    }

    private func saveNoteImmediately() {
        guard hasNote || !noteText.isEmpty,
              noteText != lastSavedNoteText else { return }
        saveNote(text: noteText)
    }

    func deleteScreenshot(_ screenshot: MeetingScreenshotRecord) {
        deleteScreenshots(ids: [screenshot.id], meetingId: screenshot.meetingId)
    }

    func deleteScreenshots(ids: Set<UUID>) {
        guard let meetingId = currentMeetingId else { return }
        deleteScreenshots(ids: ids, meetingId: meetingId)
    }

    private func deleteScreenshots(ids: Set<UUID>, meetingId: UUID) {
        guard !ids.isEmpty,
              !isSummaryGenerating,
              !isDeletingScreenshots,
              let dbQueue = activeDbQueueForSessionControls,
              let vaultURL = currentVaultURL else { return }
        let screenshotIds = ids
        isDeletingScreenshots = true
        Task { [weak self] in
            defer { self?.isDeletingScreenshots = false }
            do {
                let deletedScreenshots = try await MeetingRepository(dbQueue: dbQueue).deleteScreenshots(
                    ids: screenshotIds,
                    meetingId: meetingId
                )
                guard !deletedScreenshots.isEmpty else { return }
                for screenshot in deletedScreenshots {
                    await ScreenshotImageLoader.shared.remove(screenshotID: screenshot.id)
                }
                do {
                    try await Task.detached(priority: .utility) {
                        try ScreenshotExportService.deleteExportedScreenshots(
                            vaultURL: vaultURL,
                            screenshots: deletedScreenshots
                        )
                    }.value
                } catch {
                    captionViewModelLogger.error("Failed to delete exported screenshots from the Vault: \(error)")
                    ErrorReportingService.capture(error, context: ["source": "deleteExportedScreenshots"])
                }
                guard let self, self.currentMeetingId == meetingId else { return }
                let deletedIds = Set(deletedScreenshots.map(\.id))
                self.screenshotStore.remove(ids: deletedIds, meetingID: meetingId)
            } catch {
                captionViewModelLogger.error("Failed to delete screenshots: \(error)")
                ErrorReportingService.capture(error, context: ["source": "deleteScreenshots"])
            }
        }
    }

    func downloadScreenshot(_ screenshot: MeetingScreenshotRecord) {
        let fileExtension = ImageEncoder.fileExtension(mimeType: screenshot.mimeType, data: screenshot.imageData)
        let panel = NSSavePanel()
        if let contentType = UTType(filenameExtension: fileExtension) {
            panel.allowedContentTypes = [contentType]
        }
        panel.nameFieldStringValue = "screenshot_\(Self.fileDateFormatter.string(from: screenshot.capturedAt)).\(fileExtension)"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try screenshot.imageData.write(to: url, options: .atomic)
            } catch {
                captionViewModelLogger.error("Failed to download screenshot: \(error)")
                ErrorReportingService.capture(error, context: ["source": "downloadScreenshot"])
                self?.errorMessage = L10n.screenshotDownloadFailed(error.localizedDescription)
            }
        }
    }

    func exportTranscript() {
        guard let meetingId = currentMeetingId,
              let dbQueue = currentDbQueue else { return }
        let recordingSessions = store.recordingSessions
        let timeBase = store.timeBase

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "transcript_\(Self.fileDateFormatter.string(from: store.recordingStartTime ?? Date())).txt"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                self.usageTelemetryReporter(.export(.started, destination: .localFiles, trigger: .manual))
                guard await self.retryFailedPersistenceIfNeeded() else {
                    self.usageTelemetryReporter(.export(.failed(.export), destination: .localFiles, trigger: .manual))
                    return
                }
                do {
                    try await Task.detached(priority: .userInitiated) {
                        let text = try FullTranscriptLoader.plainText(
                            meetingId: meetingId,
                            dbQueue: dbQueue,
                            recordingSessions: recordingSessions,
                            timeBase: timeBase
                        )
                        try text.write(to: url, atomically: true, encoding: .utf8)
                    }.value
                    self.usageTelemetryReporter(.export(.completed, destination: .localFiles, trigger: .manual))
                } catch {
                    self.errorMessage = error.localizedDescription
                    self.usageTelemetryReporter(.export(.failed(.export), destination: .localFiles, trigger: .manual))
                }
            }
        }
    }

    // MARK: - Pipeline Construction

    private func handleTranscriptProjectionEvent(_ event: TranscriptionEvent) {
        guard let plan = activeTranscriptionPlan else { return }
        TranscriptionEventRouter.routeTranscriptProjection(
            event,
            plan: plan,
            transcriptStore: activeTranscriptStore
        )
    }

    private func handleObservedTranscriptionEvent(_ event: TranscriptionEvent) {
        guard let plan = activeTranscriptionPlan else { return }
        TranscriptionEventRouter.routeLiveCaption(
            event,
            plan: plan,
            liveCaptionStore: liveCaptionStore
        )
        guard case let .failure(_, _, sourceLabel, message) = event else { return }

        let source = RecordingAudioSource(speakerLabel: sourceLabel)
        errorMessage = message
        if case .starting = recordingLifecycle {
            if plan.finalMode == .realtime {
                pendingRealtimeRecognitionFailure = (source, message)
            } else {
                pendingLiveSubtitleWarning = message
            }
        }
    }

    private func forwardFinalizedLiveTranscript(_ delivery: FinalizedLiveTranscriptRelay.Delivery) {
        guard let plan = activeTranscriptionPlan,
              plan.liveChatEnabled,
              delivery.sessionID == activeRecordingSessionId else { return }
        finalizedLiveTranscriptHandler?(delivery.text, delivery.wasTruncated)
    }

    private func controllerSourceConfiguration(
        for source: RecordingAudioSource
    ) -> RecordingSessionController.SourceConfiguration {
        RecordingSessionController.SourceConfiguration(
            source: source,
            captureDeviceID: source == .microphone ? microphoneCaptureDeviceID : nil,
            forcesEchoCancellationForExternalMicrophone: source == .microphone
                && AppSettings.shared.forceEchoCancellationForExternalMicrophone
        )
    }

    private func controllerSourceConfigurations() -> [RecordingSessionController.SourceConfiguration] {
        enabledRecordingAudioSources.map { source in
            controllerSourceConfiguration(for: source)
        }
    }

    private func handleControllerRuntimeFailure(
        source: RecordingAudioSource?,
        message: String,
        isFatal: Bool,
        recordingSessionId: UUID
    ) {
        guard activeRecordingSessionId == recordingSessionId else { return }
        errorMessage = message
        if case .starting = recordingLifecycle {
            if isFatal {
                pendingRealtimeRecognitionFailure = (source, message)
            } else {
                pendingLiveSubtitleWarning = message
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self,
                  self.activeRecordingSessionId == recordingSessionId else { return }
            let snapshot = await self.recordingSessionController.snapshot()
            if let snapshot, snapshot.sessionId == recordingSessionId {
                self.applyControllerSnapshot(snapshot)
            }
            if isFatal {
                if var telemetry = self.activeRecordingTelemetryContext {
                    let sourceWasRemoved = source.map { snapshot?.enabledSources.contains($0) == false } ?? false
                    telemetry.recordingFailureStage = sourceWasRemoved ? .capture : .stop
                    if telemetry.mode == .realtime {
                        telemetry.transcriptionFailureStage = .transcription
                    }
                    self.activeRecordingTelemetryContext = telemetry
                }
                self.stopListening()
            }
        }
    }

    private func handleControllerAudioLevel(
        source: RecordingAudioSource,
        level: Double,
        recordingSessionId: UUID
    ) {
        guard activeRecordingSessionId == recordingSessionId,
              recordingLifecycle == .starting(recordingSessionId) ||
              recordingLifecycle == .recording(recordingSessionId) else { return }
        recordingAudioLevelStore.update(source: source, level: level)
    }

    private func setActiveControllerSources(_ sources: Set<RecordingAudioSource>) {
        activeControllerSources = sources
        recordingAudioLevelStore.retain(sources: sources)
        if sources.isEmpty {
            appliedLiveRecognitionLocaleIdentifier = nil
        }
    }

    private func applyControllerSnapshot(_ snapshot: RecordingSessionController.Snapshot) {
        setActiveControllerSources(snapshot.enabledSources)
        appliedLiveRecognitionLocaleIdentifier = snapshot.liveRecognitionLocaleIdentifier
    }

    private func appliedLiveRecognitionLocale() -> Locale {
        Locale(identifier: liveRecognitionLocaleIdentifier)
    }

    private func handleLiveSubtitleSettingChange(isEnabled: Bool) {
        guard var plan = activeTranscriptionPlan,
              let recordingSessionId = activeRecordingSessionId else { return }
        guard plan.liveSubtitlesEnabled != isEnabled else { return }
        let previousValue = plan.liveSubtitlesEnabled
        let captionStoreWasActive = liveCaptionStore.activeSessionId == recordingSessionId

        switch recordingLifecycle {
        case let .starting(sessionId) where sessionId == recordingSessionId:
            plan.liveSubtitlesEnabled = isEnabled
            activeTranscriptionPlan = plan
            if isEnabled {
                liveCaptionStore.start(sessionId: recordingSessionId)
            }
            return
        case let .recording(sessionId) where sessionId == recordingSessionId:
            break
        default:
            return
        }

        plan.liveSubtitlesEnabled = isEnabled
        activeTranscriptionPlan = plan

        if isEnabled {
            liveCaptionStore.start(sessionId: recordingSessionId)
            if plan.persistsRealtimeTranscript {
                liveCaptionStore.seed(activeTranscriptStore.segments, sessionId: recordingSessionId)
            }
        }

        enqueueRecordingConfiguration { [weak self] _ in
            guard let self,
                  self.activeTranscriptionPlan?.liveSubtitlesEnabled == isEnabled else { return }
            do {
                let locale = self.appliedLiveRecognitionLocale()
                let snapshot = try await self.recordingSessionController.setLiveSubtitlesEnabled(
                    isEnabled,
                    translateSegment: self.translationHandler(for: locale)
                )
                self.applyControllerSnapshot(snapshot)
            } catch {
                self.errorMessage = error.localizedDescription
                self.restoreLiveSubtitleSetting(
                    previousValue,
                    recordingSessionId: recordingSessionId,
                    clearsNewCaptionStore: isEnabled && !captionStoreWasActive
                )
            }
        }
    }

    private func restoreLiveSubtitleSetting(
        _ isEnabled: Bool,
        recordingSessionId: UUID,
        clearsNewCaptionStore: Bool
    ) {
        guard activeRecordingSessionId == recordingSessionId,
              var plan = activeTranscriptionPlan else { return }
        plan.liveSubtitlesEnabled = isEnabled
        activeTranscriptionPlan = plan
        AppSettings.shared.liveSubtitleOverlayEnabled = isEnabled

        if isEnabled {
            liveCaptionStore.start(sessionId: recordingSessionId)
        } else if clearsNewCaptionStore {
            liveCaptionStore.clear()
        }
    }

    private func reconcileStartingPlan(
        _ initialPlan: TranscriptionSessionPlan,
        recordingSessionId: UUID
    ) async throws -> TranscriptionSessionPlan {
        var plan = initialPlan
        while recordingLifecycle == .starting(recordingSessionId) {
            let desiredSubtitles = activeTranscriptionPlan?.liveSubtitlesEnabled
                ?? AppSettings.shared.liveSubtitleOverlayEnabled
            let desiredLiveChat = activeTranscriptionPlan?.liveChatEnabled ?? isChatLiveModeEnabled
            guard plan.liveSubtitlesEnabled != desiredSubtitles ||
                plan.liveChatEnabled != desiredLiveChat else { return plan }

            try ensureSessionIsActive(recordingSessionId)
            guard activeTranscriptionPlan?.liveSubtitlesEnabled == desiredSubtitles,
                  activeTranscriptionPlan?.liveChatEnabled == desiredLiveChat else { continue }

            plan.liveSubtitlesEnabled = desiredSubtitles
            plan.liveChatEnabled = desiredLiveChat
            return plan
        }
        throw CancellationError()
    }

    private func reconcileStartingLiveConfiguration(
        _ initialPlan: TranscriptionSessionPlan,
        recordingSessionId: UUID
    ) async throws -> TranscriptionSessionPlan {
        var appliedPlan = initialPlan
        while recordingLifecycle == .starting(recordingSessionId) {
            guard let latestPlan = activeTranscriptionPlan else { throw CancellationError() }
            if appliedPlan.liveSubtitlesEnabled != latestPlan.liveSubtitlesEnabled {
                let locale = appliedLiveRecognitionLocale()
                let snapshot = try await recordingSessionController.setLiveSubtitlesEnabled(
                    latestPlan.liveSubtitlesEnabled,
                    translateSegment: translationHandler(for: locale)
                )
                applyControllerSnapshot(snapshot)
                appliedPlan = snapshot.plan
            }
            if appliedPlan.liveChatEnabled != latestPlan.liveChatEnabled {
                let locale = appliedLiveRecognitionLocale()
                let snapshot = try await recordingSessionController.setLiveChatEnabled(
                    latestPlan.liveChatEnabled,
                    translateSegment: translationHandler(for: locale)
                )
                applyControllerSnapshot(snapshot)
                appliedPlan = snapshot.plan
            }
            guard activeTranscriptionPlan?.liveSubtitlesEnabled == latestPlan.liveSubtitlesEnabled,
                  activeTranscriptionPlan?.liveChatEnabled == latestPlan.liveChatEnabled else {
                continue
            }
            return latestPlan
        }
        throw CancellationError()
    }

    private func translationHandler(for locale: Locale) -> SpeechTranscriberService.SegmentTranslationHandler? {
        let sourceLocaleIdentifier = locale.identifier
        let translationService = transcriptTranslationService
        return { segment in
            let configuration = await MainActor.run {
                (
                    isEnabled: AppSettings.shared.liveSubtitleTranslationEnabled,
                    targetLanguageIdentifier: AppSettings.shared.liveSubtitleTranslationTargetLanguage
                )
            }
            guard configuration.isEnabled,
                  TranscriptTranslationLanguage.shouldTranslate(
                      transcriptionLocaleIdentifier: sourceLocaleIdentifier,
                      targetLanguageIdentifier: configuration.targetLanguageIdentifier
                  )
            else {
                return nil
            }
            return await translationService.translate(
                segment.text,
                from: sourceLocaleIdentifier,
                to: configuration.targetLanguageIdentifier
            )
        }
    }

    // MARK: - Private Helpers

    private func ensureSessionIsActive(_ recordingSessionId: UUID) throws {
        guard isSessionActive(recordingSessionId), !isTerminationRequested, !Task.isCancelled else {
            throw CancellationError()
        }
    }

    private func isSessionActive(_ recordingSessionId: UUID) -> Bool {
        switch recordingLifecycle {
        case let .starting(sessionId), let .recording(sessionId):
            sessionId == recordingSessionId
        case .idle, .stopping:
            false
        }
    }
}
