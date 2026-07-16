// Recording, transcription, and persistence state remain under one established MainActor owner.
// swiftlint:disable file_length

import AppKit
import Combine
import CoreAudio
import CoreMedia
import GRDB
import os
@preconcurrency import ScreenCaptureKit
import Speech
import SwiftUI
import UniformTypeIdentifiers

private let captionViewModelLogger = Logger(subsystem: "com.dahlia", category: "CaptionViewModel")

private enum ScreenshotError: LocalizedError {
    case encodingFailed
    case displayUnavailable
    case imageUnavailable
    case sourceUnavailable

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            L10n.screenshotEncodingFailed
        case .displayUnavailable:
            L10n.screenshotDisplayUnavailable
        case .imageUnavailable:
            L10n.screenshotImageUnavailable
        case .sourceUnavailable:
            L10n.screenshotSourceUnavailable
        }
    }
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
    let appendContext: MeetingRepository.AppendRecordingContext?
    let recordingStartTime: Date
    let recordingSessionId: UUID
    let transcriptionMode: TranscriptionMode
    let persistencePolicy: TranscriptPersistencePolicy
    let retainAudioAfterBatch: Bool
    let draftMeeting: DraftMeeting?
}

private struct RecordingStartRollbackState {
    let segments: [TranscriptSegment]
    let recordingSessions: [RecordingSessionTimeline]
    let recordingStartTime: Date?
}

private struct RecordingControllerStartRequest {
    let dbQueue: DatabaseQueue
    let meetingId: UUID?
    let sessionId: UUID
    let startedAt: Date
    let plan: TranscriptionSessionPlan
    let locale: Locale
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

    @Published var isListening = false
    @Published var isFinalizingRecording = false
    @Published var analyzerReady = false
    @Published var isPreparingAnalyzer = false
    @Published private(set) var activeTranscriptionMode: TranscriptionMode?
    @Published private(set) var batchTranscriptionState: BatchTranscriptionState?
    @Published var pendingBatchTranscriptionConfirmation: BatchTranscriptionConfirmation?
    @Published var errorMessage: String?
    @Published var availableMicrophones: [MicrophoneDevice] = []
    @Published private(set) var defaultInputDeviceID: AudioDeviceID?
    @Published private var hasResolvedDefaultInputDevice = false
    @Published var microphoneSelection: MicrophoneSelection = .systemDefault
    @Published var isSystemAudioEnabled = true
    @Published var selectedLocale: String = AppSettings.shared.transcriptionLocale {
        didSet {
            guard selectedLocale != oldValue else { return }
            updateFilteredLocales()
            guard !isSynchronizingSelectedLocale else { return }
            applyLocaleChange(from: oldValue, to: selectedLocale)
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

    // MARK: - Summary State

    @Published var summaryGeneratingMeetingId: UUID?
    var isSummaryGenerating: Bool { summaryGeneratingMeetingId != nil }
    private var pendingBatchSummaryRequestsBySessionId: [UUID: (meetingId: UUID, exportOptions: SummaryExportOptions)] = [:]
    @Published var summaryError: String?
    @Published private(set) var googleDocsExportError: String?
    private var isExportingCurrentSummaryToGoogleDocs = false
    private var isGoogleDocsExportBusy = false
    private var googleDocsExportWaiters: [CheckedContinuation<Void, Never>] = []
    @Published var lastSummaryURL: URL?
    @Published var currentSummaryGoogleFileId: String?
    @Published var currentSummaryDocument: SummaryDocument?
    /// Summary タブへの切り替えをリクエストするフラグ。
    @Published var requestShowSummaryTab = false
    /// 要約生成の進捗トースト状態。
    let summaryProgress = SummaryProgressState()

    // MARK: - Note State

    @Published var noteText = ""
    private var hasNote = false
    private var currentNoteCreatedAt: Date?
    private var noteAutoSaveCancellable: AnyCancellable?
    private var lastSavedNoteText: String?

    // MARK: - Screenshot State

    @Published var screenshots: [MeetingScreenshotRecord] = []
    @Published private(set) var isDeletingScreenshots = false
    /// キャプチャ対象として選択可能なウィンドウ一覧。
    @Published var availableWindows: [ScreenshotWindowOption] = []
    /// スクリーンショット取得対象。未設定の場合はキャプチャしない。
    @Published var screenshotCaptureSource: ScreenshotCaptureSource = .none {
        didSet {
            guard screenshotCaptureSource != oldValue else { return }
            lastSavedAutomaticScreenshotFingerprint = nil
            handleScreenshotCaptureSourceChange()
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
            screenshots: screenshots
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
        googleDocsExportError = nil
        defer { isExportingCurrentSummaryToGoogleDocs = false }

        let context = SummaryRenderContext(
            meetingId: meetingId,
            createdAt: store.timeBase,
            screenshots: screenshots
        )
        let fileName = lastSummaryURL?.lastPathComponent
            ?? "\(document.title.nilIfBlank ?? L10n.summary).rtf"
        let dbQueue = currentDbQueue

        do {
            let fileId = try await exportSummaryToGoogleDocs(
                document: document,
                context: context,
                fileName: fileName
            )
            try persistGoogleDocsFileId(fileId, meetingId: meetingId, dbQueue: dbQueue)
            if let url = URL(string: "https://docs.google.com/document/d/\(fileId)/edit") {
                NSWorkspace.shared.open(url)
            }
            return true
        } catch {
            let message = GoogleAuthErrorFormatter.message(
                for: error,
                defaultMessage: L10n.googleDocsExportFailed
            )
            googleDocsExportError = message
            ErrorReportingService.capture(error, context: ["source": "googleDocsExport"])
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
        guard let defaultDeviceID = defaultInputDeviceID,
              let deviceName = availableMicrophones.first(where: { $0.id == defaultDeviceID })?.name else {
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

    /// 少なくとも 1 つの音声ソースが有効か。
    var hasEnabledAudioSource: Bool { isMicEnabled || isSystemAudioEnabled }

    var canBeginRecording: Bool {
        recordingLifecycle == .idle
            && !isFinalizingRecording
            && hasEnabledAudioSource
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

    /// 録音対象の文字起こし ID。
    /// recordingContext 初期化前（録音開始〜別トランスクリプトへ遷移前）は currentMeetingId で補う。
    var recordingMeetingId: UUID? {
        recordingContext?.meetingId ?? (isListening ? currentMeetingId : nil)
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

    var canTakeScreenshot: Bool {
        activeMeetingIdForSessionControls != nil
            && activeDbQueueForSessionControls != nil
            && screenshotCaptureSource.isSelected
    }

    // MARK: - Private

    private var currentDbQueue: DatabaseQueue?
    private var persistenceService: MeetingPersistenceService?
    private var transcriptionEventPipeline: TranscriptionEventPipeline?
    private var batchTranscriptionCoordinator: BatchTranscriptionCoordinator?
    private let recordingSessionController = RecordingSessionController()
    private var activeTranscriptionPlan: TranscriptionSessionPlan?
    private var activeRecordingSessionId: UUID?
    private var activeControllerSources: Set<RecordingAudioSource> = []
    private var recordingLifecycle: RecordingLifecycle = .idle
    private var recordingConfigurationTasks: [Int: Task<Void, Never>] = [:]
    private var nextRecordingConfigurationID = 0
    private var pendingRealtimeRecognitionFailure: (source: RecordingAudioSource?, message: String)?
    private var pendingLiveSubtitleWarning: String?
    private var startingMicrophoneSelection: MicrophoneSelection?
    private var startingSystemAudioEnabled: Bool?
    private var startingLocaleIdentifier: String?
    private var settingsCancellable: AnyCancellable?
    private var storeSegmentsCancellable: AnyCancellable?
    private var transcriptionLocaleCancellable: AnyCancellable?
    private var liveSubtitleSettingsCancellable: AnyCancellable?
    private var automaticScreenshotSettingsCancellables: Set<AnyCancellable> = []
    private var automaticScreenshotTask: Task<Void, Never>?
    private var lastSavedAutomaticScreenshotFingerprint: ScreenshotFingerprint?
    private var meetingLoadTask: Task<Void, Never>?
    private var isSynchronizingSelectedLocale = false
    private let audioHardwareQueryService: AudioHardwareQueryService
    private let transcriptTranslationService = TranscriptTranslationService()

    private nonisolated static let preferredTranscriptionLocaleFallbacksByLanguage = [
        "en": "en_US",
        "ja": "ja_JP",
    ]

    private var activeDbQueueForSessionControls: DatabaseQueue? {
        recordingContext?.dbQueue ?? currentDbQueue
    }

    init(audioHardwareQueryService: AudioHardwareQueryService = .shared) {
        self.audioHardwareQueryService = audioHardwareQueryService
        bindStoreSegments()
        Task { [weak self] in
            await self?.refreshAvailableMicrophones()
        }

        // AppSettings の表示言語設定変更を監視
        settingsCancellable = UserDefaults.standard
            .publisher(for: \.enabledLocaleIdentifiers)
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
                guard let self, self.selectedLocale != localeIdentifier else { return }
                self.selectedLocale = localeIdentifier
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
                self?.handleAutomaticScreenshotSettingsChange()
            }
            .store(in: &automaticScreenshotSettingsCancellables)

        UserDefaults.standard
            .publisher(for: \.automaticScreenshotIntervalSeconds)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.handleAutomaticScreenshotIntervalChange()
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
        recoverExistingSessions: Bool = true
    ) {
        guard batchTranscriptionCoordinator == nil else { return }
        let coordinator = BatchTranscriptionCoordinator(
            dbQueue: dbQueue,
            managedRootURL: managedRootURL
        ) { [weak self] update in
            await self?.handleBatchTranscriptionUpdate(update)
        }
        batchTranscriptionCoordinator = coordinator
        guard recoverExistingSessions else { return }
        Task {
            await coordinator.recoverAndEnqueue()
        }
    }

    func retryBatchTranscription() {
        guard case let .failed(sessionId, _) = batchTranscriptionState,
              let coordinator = batchTranscriptionCoordinator else { return }
        batchTranscriptionState = .queued(sessionId: sessionId)
        Task {
            await coordinator.enqueue(sessionId: sessionId)
        }
    }

    func batchTranscriptionLocaleOptions(preferredIdentifier: String) -> [Locale] {
        var locales = filteredLocales.isEmpty ? supportedLocales : filteredLocales
        if !locales.contains(where: { $0.identifier == preferredIdentifier }) {
            locales.append(Locale(identifier: preferredIdentifier))
        }
        return locales.sortedByLocalizedName()
    }

    func presentBatchTranscriptionConfirmation() {
        guard case let .awaitingConfirmation(sessionId) = batchTranscriptionState,
              let meetingId = currentMeetingId else { return }
        presentBatchTranscriptionConfirmation(
            sessionId: sessionId,
            meetingId: meetingId,
            suggestedLocaleIdentifier: selectedLocale,
            dbQueue: currentDbQueue
        )
    }

    func postponeBatchTranscription() {
        pendingBatchTranscriptionConfirmation = nil
    }

    func confirmBatchTranscription(
        localeIdentifier: String,
        retainAudioAfterBatch: Bool
    ) {
        guard let confirmation = pendingBatchTranscriptionConfirmation,
              let coordinator = batchTranscriptionCoordinator else { return }
        let retryConfirmation = BatchTranscriptionConfirmation(
            sessionId: confirmation.sessionId,
            meetingId: confirmation.meetingId,
            suggestedLocaleIdentifier: localeIdentifier,
            retainAudioAfterBatch: retainAudioAfterBatch
        )
        let settings = AppSettings.shared
        if settings.generateSummaryAfterBatchTranscription {
            pendingBatchSummaryRequestsBySessionId[confirmation.sessionId] = (
                meetingId: confirmation.meetingId,
                exportOptions: settings.batchSummaryExportOptions
            )
        } else {
            pendingBatchSummaryRequestsBySessionId.removeValue(forKey: confirmation.sessionId)
        }
        pendingBatchTranscriptionConfirmation = nil
        if currentMeetingId == confirmation.meetingId {
            batchTranscriptionState = .queued(sessionId: confirmation.sessionId)
        }

        Task {
            do {
                try await coordinator.confirmAndEnqueue(
                    sessionId: confirmation.sessionId,
                    localeIdentifier: localeIdentifier,
                    retainAudioAfterBatch: retainAudioAfterBatch
                )
            } catch {
                if currentMeetingId == confirmation.meetingId {
                    batchTranscriptionState = .awaitingConfirmation(sessionId: confirmation.sessionId)
                }
                errorMessage = error.localizedDescription
                pendingBatchTranscriptionConfirmation = retryConfirmation
                MainWindowOpener.shared.openMainWindow()
            }
        }
    }

    func discardFailedBatchTranscription() {
        guard case let .failed(sessionId, _) = batchTranscriptionState,
              let meetingId = currentMeetingId,
              let dbQueue = currentDbQueue else { return }
        Task {
            do {
                let repository = MeetingRepository(dbQueue: dbQueue)
                guard try await repository.discardFailedBatchSessionSafely(id: sessionId) else { return }
                pendingBatchSummaryRequestsBySessionId.removeValue(forKey: sessionId)
                try refreshBatchTranscriptionState(meetingId: meetingId, dbQueue: dbQueue)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshBatchTranscriptionState(meetingId: UUID, dbQueue: DatabaseQueue) throws {
        let sessions = try dbQueue.read { db in
            try RecordingSessionRecord
                .filter(Column("meetingId") == meetingId)
                .order(Column("startedAt").asc)
                .fetchAll(db)
        }
        guard currentMeetingId == meetingId else { return }
        batchTranscriptionState = sessions
            .reversed()
            .compactMap { BatchTranscriptionState.derive(from: $0) }
            .first(where: \.blocksSummaryGeneration)
    }

    func handleBatchTranscriptionUpdate(_ update: BatchTranscriptionUpdate) async {
        guard currentMeetingId == update.meetingId,
              !(isBatchRecording && recordingMeetingId == update.meetingId) else { return }
        batchTranscriptionState = update.state
        guard case .completed = update.state,
              canReloadMeetingAfterBatchCompletion(update.meetingId) else { return }
        await reloadCurrentMeetingAfterBatchCompletion(meetingId: update.meetingId)
    }

    private func canReloadMeetingAfterBatchCompletion(_ meetingId: UUID) -> Bool {
        !isListening || recordingMeetingId != meetingId
    }

    private func reloadCurrentMeetingAfterBatchCompletion(meetingId: UUID) async {
        guard let dbQueue = currentDbQueue,
              let vaultURL = currentVaultURL,
              currentMeetingId == meetingId else { return }
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
            store.recordingStartTime = loaded.createdAt
            store.loadRecordingSessions(loaded.recordingSessions)
            store.loadSegments(loaded.segments)
            applyLoadedDetail(loaded)
            generatePendingBatchSummaryIfReady(meetingId: meetingId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func bindStoreSegments() {
        currentMeetingHasTranscriptSegments = !store.segments.isEmpty
        storeSegmentsCancellable = store.$segments
            .map { !$0.isEmpty }
            .removeDuplicates()
            .sink { [weak self] hasSegments in
                self?.currentMeetingHasTranscriptSegments = hasSegments
            }
    }

    /// supportedLocales と設定から filteredLocales を再計算する。
    private func updateFilteredLocales() {
        let settings = AppSettings.shared
        let enabled = settings.enabledLocaleIdentifiers
        if enabled.isEmpty {
            filteredLocales = supportedLocales
        } else {
            filteredLocales = supportedLocales.filter { locale in
                enabled.contains(locale.identifier)
                    || locale.identifier == selectedLocale
            }
        }
    }

    nonisolated static func resolvedSupportedLocaleIdentifier(
        preferredIdentifier: String,
        supportedLocales: [Locale]
    ) -> String {
        let trimmedIdentifier = preferredIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedIdentifier = normalizedLocaleIdentifier(from: trimmedIdentifier)
        let supportedLocaleIdentifiers = Set(supportedLocales.map(\.identifier))

        if supportedLocaleIdentifiers.contains(normalizedIdentifier) {
            return normalizedIdentifier
        }

        let preferredLanguageIdentifier = TranscriptTranslationLanguage.normalizedLanguageIdentifier(from: trimmedIdentifier)
        if let preferredFallback = preferredTranscriptionLocaleFallbacksByLanguage[preferredLanguageIdentifier],
           supportedLocaleIdentifiers.contains(preferredFallback) {
            return preferredFallback
        }

        let sortedLocales = supportedLocales.sorted(by: { $0.identifier < $1.identifier })

        if let sameLanguageLocale = sortedLocales
            .first(where: {
                TranscriptTranslationLanguage.normalizedLanguageIdentifier(from: $0.identifier) == preferredLanguageIdentifier
            }) {
            return sameLanguageLocale.identifier
        }

        for fallback in preferredTranscriptionLocaleFallbacksByLanguage.values.sorted() {
            if supportedLocaleIdentifiers.contains(fallback) {
                return fallback
            }
        }

        return sortedLocales.first?.identifier ?? normalizedIdentifier
    }

    private nonisolated static func normalizedLocaleIdentifier(from identifier: String) -> String {
        guard !identifier.isEmpty else { return identifier }

        let locale = Locale(identifier: identifier)
        guard let languageCode = locale.language.languageCode?.identifier.nilIfBlank else {
            return identifier
                .replacingOccurrences(of: "-", with: "_")
                .split(separator: "@", maxSplits: 1)
                .first
                .map(String.init) ?? identifier
        }

        guard let regionCode = locale.region?.identifier.nilIfBlank else {
            return languageCode
        }

        return "\(languageCode)_\(regionCode)"
    }

    private func resolvedSelectedLocale() -> Locale {
        let resolvedIdentifier = Self.resolvedSupportedLocaleIdentifier(
            preferredIdentifier: selectedLocale,
            supportedLocales: supportedLocales
        )
        synchronizeSelectedLocaleIfNeeded(resolvedIdentifier)
        return Locale(identifier: resolvedIdentifier)
    }

    private func synchronizeSelectedLocaleIfNeeded(_ localeIdentifier: String) {
        guard selectedLocale != localeIdentifier else { return }
        isSynchronizingSelectedLocale = true
        selectedLocale = localeIdentifier
        isSynchronizingSelectedLocale = false
        AppSettings.shared.transcriptionLocale = localeIdentifier
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
        let createdAt: Date?
        let recordingSessionRecords: [RecordingSessionRecord]
        let recordingSessions: [RecordingSessionTimeline]
        let segments: [TranscriptSegment]
        let screenshots: [MeetingScreenshotRecord]
        let summaryDocument: SummaryDocument?
        let googleFileId: String?
        let lastSummaryURL: URL?
        let note: MeetingNoteRecord?
    }

    private nonisolated static func fetchLoadedMeetingData(
        meetingId: UUID,
        dbQueue: DatabaseQueue,
        vaultURL: URL
    ) throws -> LoadedMeetingData {
        let repo = MeetingRepository(dbQueue: dbQueue)
        let detail = try repo.fetchMeetingDetail(id: meetingId)
        let recordingSessions = detail.recordingSessions.map(RecordingSessionTimeline.init)
        let segments = detail.segments.map(TranscriptSegment.init(from:))
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

        return try LoadedMeetingData(
            createdAt: detail.meeting?.createdAt,
            recordingSessionRecords: detail.recordingSessions,
            recordingSessions: recordingSessions,
            segments: segments,
            screenshots: detail.screenshots,
            summaryDocument: detail.summary?.loadDocument(),
            googleFileId: googleDocsExport?.googleDocumentID,
            lastSummaryURL: lastSummaryURL,
            note: detail.note
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
            } catch is CancellationError {
                return
            } catch {
                captionViewModelLogger.error("Failed to load meeting \(meetingId): \(error)")
                ErrorReportingService.capture(error, context: ["source": "loadMeeting"])
                return
            }

            guard !Task.isCancelled, self.currentMeetingId == meetingId else { return }

            self.store.recordingStartTime = loaded.createdAt
            self.store.loadRecordingSessions(loaded.recordingSessions)
            self.store.loadSegments(loaded.segments)
            self.applyLoadedDetail(loaded)
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
        guard !isFinalizingRecording else { return }

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
        from event: CalendarEvent,
        dbQueue: DatabaseQueue,
        projectURL: URL? = nil,
        projectId: UUID? = nil,
        projectName: String? = nil,
        vaultURL: URL
    ) {
        guard !isFinalizingRecording else { return }

        resetMeetingState()
        let draftId = UUID.v7()
        currentMeetingId = nil
        currentProjectURL = projectURL
        currentProjectId = projectId
        currentProjectName = projectName
        currentVaultURL = vaultURL
        currentDbQueue = dbQueue
        draftMeeting = DraftMeeting(
            id: draftId,
            title: event.title,
            linkedCalendarEvent: event,
            projectURL: projectURL,
            projectId: projectId,
            projectName: projectName
        )
        setupNoteAutoSave()
    }

    func updateDraftMeetingTitle(_ title: String) {
        guard draftMeeting != nil else { return }
        draftMeeting?.title = title
    }

    func materializeDraftMeeting(
        projectURL: URL? = nil,
        projectId: UUID? = nil,
        projectName: String? = nil
    ) -> UUID? {
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
        setMeetingContext(
            id: meetingId,
            dbQueue: dbQueue,
            projectURL: resolvedProject?.url ?? requestedProjectURL,
            projectId: assignedProjectId,
            projectName: resolvedProject?.name ?? requestedProjectName,
            vaultURL: vaultURL
        )
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

        if isListening {
            saveRecordingContextIfNeeded()
            store = TranscriptStore()
            screenshots = []
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
    }

    /// 録音対象のトランスクリプトに表示を復帰する。
    func returnToRecordingMeeting() {
        guard let ctx = recordingContext else { return }
        meetingLoadTask?.cancel()
        saveNoteImmediately()

        // コンテキストを先に復元（store 代入時の objectWillChange で SwiftUI が再評価する際に
        // currentMeetingId 等が正しい値を返すようにする）
        currentMeetingId = ctx.meetingId
        currentProjectURL = ctx.projectURL
        currentProjectId = ctx.projectId
        currentProjectName = ctx.projectName
        currentVaultURL = ctx.vaultURL
        currentDbQueue = ctx.dbQueue
        batchTranscriptionState = ctx.batchTranscriptionState
        draftMeeting = nil

        store = ctx.store
        recordingContext = nil

        reloadMeetingDetail()
    }

    /// 現在の meetingId のノート・スクリーンショット・サマリーを DB から読み込み直す。
    private func reloadMeetingDetail() {
        guard let meetingId = currentMeetingId,
              let dbQueue = currentDbQueue,
              let vaultURL = currentVaultURL else { return }
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
            guard !Task.isCancelled, self.currentMeetingId == meetingId else { return }
            self.applyLoadedDetail(loaded)
        }
    }

    /// 読み込み済みデータのノート・スクリーンショット・サマリーを UI 状態に反映する。
    private func applyLoadedDetail(_ loaded: LoadedMeetingData) {
        screenshots = loaded.screenshots
        currentSummaryDocument = loaded.summaryDocument
        currentSummaryGoogleFileId = loaded.googleFileId
        lastSummaryURL = loaded.lastSummaryURL
        noteText = loaded.note?.text ?? ""
        hasNote = loaded.note != nil
        currentNoteCreatedAt = loaded.note?.createdAt
        lastSavedNoteText = noteText
        batchTranscriptionState = loaded.recordingSessionRecords
            .reversed()
            .compactMap { BatchTranscriptionState.derive(from: $0) }
            .first(where: \.blocksSummaryGeneration)
        setupNoteAutoSave()

        guard let coordinator = batchTranscriptionCoordinator,
              let visibleState = batchTranscriptionState else { return }
        Task {
            if await coordinator.isRunning(sessionId: visibleState.sessionId),
               batchTranscriptionState?.sessionId == visibleState.sessionId {
                batchTranscriptionState = .running(sessionId: visibleState.sessionId)
            }
        }
    }

    // MARK: - Private Helpers

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
        store.clear()
        screenshots = []
        resetNoteState()
        resetSummaryState()
        draftMeeting = nil
        batchTranscriptionState = nil
    }

    private func resetSummaryState() {
        currentSummaryDocument = nil
        currentSummaryGoogleFileId = nil
        lastSummaryURL = nil
        requestShowSummaryTab = false
        summaryError = nil
        googleDocsExportError = nil
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
                  try ProjectRecord.fetchOne(db, key: projectId)
              }) else { return nil }

        return (
            vaultURL.appending(path: project.name, directoryHint: .isDirectory),
            project.name
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
                let locale = self.resolvedSelectedLocale()
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

    private func applyLocaleChange(from oldLocale: String, to newLocale: String) {
        guard newLocale != oldLocale || !analyzerReady else { return }
        if case .starting = recordingLifecycle, let startingLocaleIdentifier {
            if newLocale != startingLocaleIdentifier {
                selectedLocale = startingLocaleIdentifier
            }
            AppSettings.shared.transcriptionLocale = startingLocaleIdentifier
            return
        }
        AppSettings.shared.transcriptionLocale = newLocale

        if isListening {
            enqueueRecordingConfiguration { [weak self] recordingSessionId in
                _ = await self?.rebuildPipelines(
                    reason: .localeChange,
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
        case localeChange
        case audioSourceChange(RecordingAudioSource)
    }

    @discardableResult
    private func rebuildPipelines(
        reason: PipelineRebuildReason,
        recordingSessionId: UUID
    ) async -> Bool {
        guard recordingLifecycle == .recording(recordingSessionId) else { return false }
        do {
            let snapshot: RecordingSessionController.Snapshot
            switch reason {
            case .localeChange:
                let locale = resolvedSelectedLocale()
                snapshot = try await recordingSessionController.changeLocale(
                    to: locale,
                    translateSegment: translationHandler(for: locale)
                )
            case let .audioSourceChange(source):
                let locale = resolvedSelectedLocale()
                snapshot = try await recordingSessionController.setSource(
                    controllerSourceConfiguration(for: source),
                    enabled: enabledRecordingAudioSources.contains(source),
                    translateSegment: translationHandler(for: locale)
                )
            }
            guard snapshot.sessionId == recordingSessionId else { return false }
            activeControllerSources = snapshot.enabledSources
            errorMessage = nil
            return true
        } catch {
            guard !Task.isCancelled,
                  recordingLifecycle == .recording(recordingSessionId) else { return false }
            if let snapshot = await recordingSessionController.snapshot(),
               snapshot.sessionId == recordingSessionId {
                activeControllerSources = snapshot.enabledSources
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
        case .localeChange:
            errorMessage = L10n.languageChangeFailed(error.localizedDescription)
        case .audioSourceChange:
            errorMessage = error.localizedDescription
        }
    }

    private func prepareRecordingStart(
        existingMeetingId: UUID?,
        dbQueue: DatabaseQueue,
        recordingStartTime: Date
    ) -> MeetingRepository.AppendRecordingContext? {
        persistenceService = nil
        transcriptionEventPipeline = nil
        stopAutomaticScreenshotCapture()

        guard let existingMeetingId else {
            store.recordingStartTime = recordingStartTime
            return nil
        }

        let repository = MeetingRepository(dbQueue: dbQueue)
        let context = try? repository.fetchAppendRecordingContext(forMeetingId: existingMeetingId)
        if let sessions = context?.recordingSessions, !sessions.isEmpty {
            store.loadRecordingSessions(sessions.map(RecordingSessionTimeline.init))
        }
        guard store.recordingStartTime == nil else { return context }
        if let firstSegmentStartTime = context?.firstSegmentStartTime {
            store.recordingStartTime = context?.meetingCreatedAt ?? firstSegmentStartTime
        } else {
            store.recordingStartTime = recordingStartTime
            try? repository.updateMeetingCreatedAt(id: existingMeetingId, createdAt: recordingStartTime)
        }
        return context
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
                locale: request.locale,
                sources: controllerSourceConfigurations(plan: request.plan),
                dbQueue: request.plan.recordsBatchAudio ? request.dbQueue : nil,
                meetingId: request.plan.recordsBatchAudio ? request.meetingId : nil,
                batchSampleRate: request.batchSampleRate,
                translateSegment: translationHandler(for: request.locale),
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
        }
        let snapshot = try await recordingSessionController.startPrepared()
        activeControllerSources = snapshot.enabledSources
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
        startingLocaleIdentifier = nil
        isListening = true
        errorMessage = pendingLiveSubtitleWarning
        pendingLiveSubtitleWarning = nil
        syncAutomaticScreenshotCaptureState()
    }

    private func startPersistence(_ request: PersistenceStartRequest) throws {
        if let existingMeetingId = request.existingMeetingId {
            let service = try MeetingPersistenceService(
                store: store,
                dbQueue: request.dbQueue,
                existingMeetingId: existingMeetingId,
                existingSegmentIds: request.appendContext?.segmentIds ?? [],
                recordingStartDate: request.recordingStartTime,
                recordingOffsetSeconds: request.appendContext?.nextOffsetSeconds ?? 0,
                recordingSessionId: request.recordingSessionId,
                transcriptionMode: request.transcriptionMode,
                persistencePolicy: request.persistencePolicy,
                retainAudioAfterBatch: request.retainAudioAfterBatch
            )
            persistenceService = service
            installTranscriptionEventPipeline(persistenceService: service)
            currentMeetingId = existingMeetingId
            return
        }

        let initialName = request.draftMeeting?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let service = try MeetingPersistenceService(
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

        let resolvedProject = currentVaultURL.flatMap { vaultURL in
            Self.projectContext(
                projectId: service.projectId,
                dbQueue: request.dbQueue,
                vaultURL: vaultURL
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
        transcriptionEventPipeline = TranscriptionEventPipeline(
            uiSink: { [weak self] events in
                for event in events {
                    self?.handleTranscriptionEvent(event)
                }
            },
            persistenceSink: { events in
                try await persistenceService.persist(events)
            },
            persistenceResetSink: {
                await persistenceService.reset()
            }
        )
    }

    private func completePersistenceStart(existingMeetingId: UUID?) {
        guard existingMeetingId == nil else { return }
        draftMeeting = nil
        setupNoteAutoSave()
        saveNoteImmediately()
    }

    private func handleRecordingStartFailure(
        _ error: Error,
        recordingSessionId: UUID,
        rollbackState: RecordingStartRollbackState,
        existingMeetingId: UUID?,
        previousBatchTranscriptionState: BatchTranscriptionState?
    ) async {
        guard recordingLifecycle == .starting(recordingSessionId) else { return }
        errorMessage = error.localizedDescription
        ErrorReportingService.capture(error, context: ["source": "startListening"])
        await recordingSessionController.abort()
        if let transcriptionEventPipeline {
            do {
                try await transcriptionEventPipeline.finish()
            } catch {
                ErrorReportingService.capture(error, context: ["source": "startTranscriptionPersistence"])
            }
        }
        transcriptionEventPipeline = nil
        stopAutomaticScreenshotCapture()
        await persistenceService?.cancel()
        persistenceService = nil
        activeTranscriptionMode = nil
        activeTranscriptionPlan = nil
        activeRecordingSessionId = nil
        activeControllerSources.removeAll()
        pendingRealtimeRecognitionFailure = nil
        pendingLiveSubtitleWarning = nil
        startingMicrophoneSelection = nil
        startingSystemAudioEnabled = nil
        startingLocaleIdentifier = nil
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
    }

    // MARK: - Recording Control

    func toggleListening(
        dbQueue: DatabaseQueue,
        projectURL: URL?,
        vaultId: UUID,
        projectId: UUID?,
        projectName: String? = nil,
        vaultURL: URL
    ) {
        guard !isFinalizingRecording else { return }

        switch recordingLifecycle {
        case .recording:
            stopListening()
        case .idle:
            Task {
                await startListening(
                    dbQueue: dbQueue,
                    projectURL: projectURL,
                    vaultId: vaultId,
                    projectId: projectId,
                    projectName: projectName,
                    vaultURL: vaultURL
                )
            }
        case .starting, .stopping:
            break
        }
    }

    /// 新規文字起こしで録音を開始する。
    func startListening(
        dbQueue: DatabaseQueue,
        projectURL: URL?,
        vaultId: UUID,
        projectId: UUID?,
        projectName: String? = nil,
        vaultURL: URL,
        appendingTo existingMeetingId: UUID? = nil
    ) async {
        guard recordingLifecycle == .idle, !isFinalizingRecording else { return }
        await refreshDefaultInputDevice()
        guard recordingLifecycle == .idle,
              !isFinalizingRecording,
              canStartRecording() else { return }
        let previousBatchTranscriptionState = batchTranscriptionState

        self.currentProjectURL = projectURL
        self.currentProjectId = projectId
        self.currentProjectName = projectName
        self.currentVaultURL = vaultURL
        self.currentDbQueue = dbQueue
        resetSummaryState()
        let activeDraftMeeting = draftMeeting

        let recordingSessionId = UUID.v7()
        let rollbackState = RecordingStartRollbackState(
            segments: store.segments,
            recordingSessions: store.recordingSessions,
            recordingStartTime: store.recordingStartTime
        )
        startingMicrophoneSelection = microphoneSelection
        startingSystemAudioEnabled = isSystemAudioEnabled
        startingLocaleIdentifier = selectedLocale
        recordingLifecycle = .starting(recordingSessionId)
        pendingRealtimeRecognitionFailure = nil
        pendingLiveSubtitleWarning = nil
        let transcriptionMode = AppSettings.shared.transcriptionMode
        let retainAudioAfterBatch = transcriptionMode == .batch
            && AppSettings.shared.retainAudioAfterBatchTranscription
        var transcriptionPlan = TranscriptionSessionPlan(
            finalMode: transcriptionMode,
            liveSubtitlesEnabled: AppSettings.shared.liveSubtitleOverlayEnabled,
            retainBatchAudio: retainAudioAfterBatch
        )
        let primaryLocale = resolvedSelectedLocale()
        activeTranscriptionMode = transcriptionMode
        activeTranscriptionPlan = transcriptionPlan
        activeRecordingSessionId = recordingSessionId
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
            let appendContext = prepareRecordingStart(
                existingMeetingId: existingMeetingId,
                dbQueue: dbQueue,
                recordingStartTime: recordingStartTime
            )

            try startPersistence(
                PersistenceStartRequest(
                    dbQueue: dbQueue,
                    vaultId: vaultId,
                    projectId: projectId,
                    existingMeetingId: existingMeetingId,
                    appendContext: appendContext,
                    recordingStartTime: recordingStartTime,
                    recordingSessionId: recordingSessionId,
                    transcriptionMode: transcriptionMode,
                    persistencePolicy: transcriptionPlan.persistsRealtimeTranscript ? .streaming : .deferred,
                    retainAudioAfterBatch: retainAudioAfterBatch,
                    draftMeeting: activeDraftMeeting
                )
            )
            try await prepareAndStartRecordingController(RecordingControllerStartRequest(
                dbQueue: dbQueue,
                meetingId: currentMeetingId,
                sessionId: recordingSessionId,
                startedAt: recordingStartTime,
                plan: transcriptionPlan,
                locale: primaryLocale,
                batchSampleRate: batchSampleRate
            ))

            transcriptionPlan = try await reconcileStartingLiveConfiguration(
                transcriptionPlan,
                recordingSessionId: recordingSessionId
            )
            await transcriptionEventPipeline?.flushUI()

            if let failure = pendingRealtimeRecognitionFailure {
                throw RecordingPipelineFailure(message: failure.message)
            }

            completePersistenceStart(existingMeetingId: existingMeetingId)
            markRecordingStarted(recordingSessionId: recordingSessionId)
            pendingRealtimeRecognitionFailure = nil
        } catch {
            await handleRecordingStartFailure(
                error,
                recordingSessionId: recordingSessionId,
                rollbackState: rollbackState,
                existingMeetingId: existingMeetingId,
                previousBatchTranscriptionState: previousBatchTranscriptionState
            )
        }
    }

    func stopListening() {
        guard case let .recording(activeSessionId) = recordingLifecycle,
              isListening,
              !isFinalizingRecording else { return }

        recordingLifecycle = .stopping(activeSessionId)
        isFinalizingRecording = true
        stopAutomaticScreenshotCapture()
        let configurationTasks = Array(recordingConfigurationTasks.values)
        configurationTasks.forEach { $0.cancel() }
        recordingConfigurationTasks.removeAll()
        isListening = false

        // ナビゲーション済みの場合、録音コンテキストからデータを取得
        let ctx = recordingContext
        let activeStore = ctx?.store ?? store
        let meetingId = ctx?.meetingId ?? currentMeetingId
        let projectName = ctx?.projectName ?? selectedProjectName
        let vaultURL = ctx?.vaultURL ?? currentVaultURL
        let dbQueue = ctx?.dbQueue ?? currentDbQueue
        let recordingStart = activeStore.timeBase
        let transcriptionMode = activeTranscriptionMode ?? .realtime
        let recordingSessionId = persistenceService?.recordingSessionId

        Task {
            var stopResult: RecordingSessionController.StopResult?
            do {
                stopResult = try await recordingSessionController.stop()
            } catch {
                ErrorReportingService.capture(error, context: ["source": "stopRecordingSession"])
                await recordingSessionController.abort()
            }
            for task in configurationTasks {
                await task.value
            }
            if let transcriptionEventPipeline {
                do {
                    try await transcriptionEventPipeline.finish()
                } catch {
                    ErrorReportingService.capture(error, context: ["source": "stopTranscriptionPersistence"])
                }
            }
            transcriptionEventPipeline = nil
            let persistenceResult = await persistenceService?.stop()
                ?? .failure(message: L10n.recordingSessionNotActive)
            persistenceService = nil
            recordingContext = nil
            if let persistenceFailureMessage = persistenceResult.failureMessage {
                errorMessage = persistenceFailureMessage
            }
            await recordingSessionController.completeStop()
            activeTranscriptionMode = nil
            activeTranscriptionPlan = nil
            activeRecordingSessionId = nil
            activeControllerSources.removeAll()
            pendingRealtimeRecognitionFailure = nil
            pendingLiveSubtitleWarning = nil
            startingMicrophoneSelection = nil
            startingSystemAudioEnabled = nil
            startingLocaleIdentifier = nil
            liveCaptionStore.clear()
            recordingLifecycle = .idle
            var segments = activeStore.segments
            let recordingSessions = activeStore.recordingSessions
            isFinalizingRecording = false

            if transcriptionMode == .batch, let recordingSessionId {
                await finishStoppedBatchRecording(
                    recordingSessionId: recordingSessionId,
                    stopResult: stopResult,
                    persistenceResult: persistenceResult,
                    meetingId: meetingId,
                    vaultURL: vaultURL,
                    dbQueue: dbQueue
                )
                return
            }

            if let meetingId, let dbQueue {
                segments = await mergedSegmentsForExport(
                    meetingId: meetingId,
                    dbQueue: dbQueue,
                    activeSegments: segments
                )
                if currentMeetingId == meetingId {
                    activeStore.loadSegments(segments)
                }
            }
            guard let vaultURL, let meetingId, !segments.isEmpty else { return }
            await exportFiles(
                vaultURL: vaultURL,
                meetingId: meetingId,
                projectName: projectName ?? "",
                createdAt: recordingStart,
                segments: segments,
                recordingSessions: recordingSessions
            )
        }
    }

    private func finishStoppedBatchRecording(
        recordingSessionId: UUID,
        stopResult: RecordingSessionController.StopResult?,
        persistenceResult: MeetingPersistenceStopResult,
        meetingId: UUID?,
        vaultURL: URL?,
        dbQueue: DatabaseQueue?
    ) async {
        let recordingFailed = stopResult?.batchRecordingSucceeded != true || !persistenceResult.succeeded
        if recordingFailed {
            if currentMeetingId == meetingId {
                batchTranscriptionState = .failed(
                    sessionId: recordingSessionId,
                    message: stopResult?.batchFailureMessage
                        ?? persistenceResult.failureMessage.map(L10n.batchAudioWriteFailed)
                        ?? L10n.batchAudioWriteFailed("")
                )
            }
        } else if let meetingId {
            if currentMeetingId == meetingId {
                batchTranscriptionState = .awaitingConfirmation(sessionId: recordingSessionId)
            }
            presentBatchTranscriptionConfirmation(
                sessionId: recordingSessionId,
                meetingId: meetingId,
                suggestedLocaleIdentifier: selectedLocale,
                dbQueue: dbQueue
            )
        }
        await completeBatchRecording(
            meetingId: meetingId,
            vaultURL: vaultURL,
            dbQueue: dbQueue
        )
    }

    private func presentBatchTranscriptionConfirmation(
        sessionId: UUID,
        meetingId: UUID,
        suggestedLocaleIdentifier: String,
        dbQueue: DatabaseQueue?
    ) {
        pendingBatchTranscriptionConfirmation = BatchTranscriptionConfirmation(
            sessionId: sessionId,
            meetingId: meetingId,
            suggestedLocaleIdentifier: suggestedLocaleIdentifier,
            retainAudioAfterBatch: batchAudioRetentionPreference(
                sessionId: sessionId,
                dbQueue: dbQueue
            )
        )
        MainWindowOpener.shared.openMainWindow()
    }

    private func batchAudioRetentionPreference(sessionId: UUID, dbQueue: DatabaseQueue?) -> Bool {
        let fallback = AppSettings.shared.retainAudioAfterBatchTranscription
        guard let dbQueue else { return fallback }
        return (try? dbQueue.read { db in
            try RecordingSessionRecord.fetchOne(db, key: sessionId)
        })?.retainAudioAfterBatch ?? fallback
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

    // MARK: - Summary Generation

    /// 手動で要約を実行できるかどうか。
    var canGenerateSummary: Bool {
        guard !isListening,
              !isFinalizingRecording,
              !isSummaryGenerating,
              !isDeletingScreenshots,
              currentMeetingId != nil,
              currentVaultURL != nil,
              batchTranscriptionState?.blocksSummaryGeneration != true else { return false }
        return !store.segments.isEmpty
    }

    /// プルダウンメニューから手動で要約を実行する。
    func triggerManualSummary() {
        triggerSummary(exportOptions: .manual)
    }

    private func triggerSummary(exportOptions: SummaryExportOptions) {
        guard canGenerateSummary,
              let meetingId = currentMeetingId,
              let vaultURL = currentVaultURL else { return }
        let projectURL = currentProjectURL
        let transcriptText = store.exportForSummary()
        let createdAt = store.timeBase
        let projectName = selectedProjectName ?? ""
        let segments = store.segments
        let recordingSessions = store.recordingSessions
        requestShowSummaryTab = true
        Task {
            await generateSummary(
                meetingId: meetingId,
                transcriptText: transcriptText,
                projectURL: projectURL,
                createdAt: createdAt,
                vaultURL: vaultURL,
                projectName: projectName,
                segments: segments,
                recordingSessions: recordingSessions,
                exportOptions: exportOptions
            )
        }
    }

    private func generatePendingBatchSummaryIfReady(meetingId: UUID) {
        let pendingRequests = pendingBatchSummaryRequestsBySessionId.compactMap { sessionId, request in
            request.meetingId == meetingId
                ? (sessionId: sessionId, exportOptions: request.exportOptions)
                : nil
        }
        guard currentMeetingId == meetingId,
              canGenerateSummary,
              !pendingRequests.isEmpty else { return }
        for request in pendingRequests {
            pendingBatchSummaryRequestsBySessionId.removeValue(forKey: request.sessionId)
        }
        let exportOptions = SummaryExportOptions.merging(pendingRequests.map(\.exportOptions))
        triggerSummary(exportOptions: exportOptions)
    }

    // Summary generation coordinates persistence and two optional export destinations as one user operation.
    // swiftlint:disable:next function_body_length function_parameter_count
    func generateSummary(
        meetingId: UUID,
        transcriptText: String,
        projectURL: URL?,
        createdAt: Date,
        vaultURL: URL,
        projectName: String,
        segments: [TranscriptSegment],
        recordingSessions: [RecordingSessionTimeline],
        exportOptions: SummaryExportOptions
    ) async {
        guard !transcriptText.isEmpty,
              !isDeletingScreenshots else { return }

        // 要約前にノートを即座に保存してから取得
        saveNoteImmediately()
        let currentNoteText = noteText

        summaryGeneratingMeetingId = meetingId
        summaryError = nil
        googleDocsExportError = nil
        lastSummaryURL = nil
        var progressPresentationID: UUID?

        do {
            let dbQueue = currentDbQueue
            let projectId = currentProjectId
            let repo = dbQueue.map { MeetingRepository(dbQueue: $0) }
            var screenshots: [MeetingScreenshotRecord] = []
            var promptProjectName = projectName.nilIfBlank
            var projectDescription: String?
            if let repo {
                screenshots = (try? repo.fetchScreenshots(forMeetingId: meetingId)) ?? []
                if let projectId,
                   let project = try repo.fetchProject(id: projectId) {
                    promptProjectName = project.name
                    projectDescription = project.description
                }
            }

            progressPresentationID = summaryProgress.show()
            summaryProgress.vaultExport = exportOptions.exportsToVault ? .pending : .skipped
            summaryProgress.googleDocsExport = exportOptions.exportsToGoogleDocs ? .pending : .skipped

            // LLM 要約
            summaryProgress.summaryGeneration = .running

            let generatedSummary = try await SummaryService.generateSummary(
                projectName: promptProjectName,
                projectDescription: projectDescription,
                meetingId: meetingId,
                createdAt: createdAt,
                transcriptText: transcriptText,
                noteText: currentNoteText.isEmpty ? nil : currentNoteText,
                screenshots: screenshots,
                recordingSessions: recordingSessions,
                repository: repo
            )

            // Regeneration invalidates the previous export locations. Keep the old
            // Vault path only long enough to overwrite the existing file when selected.
            let storedSummaryRelativePath = try repo?.fetchSummaryVaultRelativePath(forMeetingId: meetingId)

            if let repo {
                try repo.applyGeneratedSummary(
                    toMeetingId: meetingId,
                    document: generatedSummary.document,
                    tags: generatedSummary.document.tags
                )
            }
            summaryProgress.summaryGeneration = .completed
            if currentMeetingId == meetingId {
                currentSummaryDocument = generatedSummary.document
                currentSummaryGoogleFileId = nil
            }

            if exportOptions.exportsToVault {
                summaryProgress.vaultExport = .running
                do {
                    let fileURL = try await VaultSummaryExportService.exportSummaryBundle(
                        projectURL: projectURL,
                        vaultURL: vaultURL,
                        storedSummaryRelativePath: storedSummaryRelativePath,
                        meetingId: meetingId,
                        createdAt: createdAt,
                        projectName: projectName,
                        segments: segments,
                        recordingSessions: recordingSessions,
                        screenshots: screenshots,
                        summaryFileName: generatedSummary.fileName,
                        summaryMarkdown: generatedSummary.markdown
                    )
                    if let relativePath = VaultSummaryFileLocator.relativePath(for: fileURL, vaultURL: vaultURL) {
                        try repo?.updateSummaryVaultRelativePath(forMeetingId: meetingId, relativePath: relativePath)
                    }
                    summaryProgress.vaultExport = .completed
                    if currentMeetingId == meetingId {
                        lastSummaryURL = fileURL
                    }
                } catch {
                    summaryProgress.vaultExport = .failed(error.localizedDescription)
                    if currentMeetingId == meetingId {
                        summaryError = error.localizedDescription
                    }
                    ErrorReportingService.capture(error, context: ["source": "vaultSummaryExport"])
                }
            }

            if exportOptions.exportsToGoogleDocs {
                summaryProgress.googleDocsExport = .running
                do {
                    let fileId = try await exportSummaryToGoogleDocs(
                        document: generatedSummary.document,
                        context: SummaryRenderContext(
                            meetingId: meetingId,
                            createdAt: createdAt,
                            screenshots: screenshots
                        ),
                        fileName: generatedSummary.fileName
                    )
                    try persistGoogleDocsFileId(fileId, meetingId: meetingId, dbQueue: dbQueue)
                    summaryProgress.googleDocsExport = .completed
                } catch {
                    let message = GoogleAuthErrorFormatter.message(
                        for: error,
                        defaultMessage: L10n.googleDocsExportFailed
                    )
                    summaryProgress.googleDocsExport = .failed(message)
                    if currentMeetingId == meetingId {
                        googleDocsExportError = message
                    }
                    ErrorReportingService.capture(error, context: ["source": "batchGoogleDocsExport"])
                }
            }
        } catch {
            if currentMeetingId == meetingId {
                summaryError = error.localizedDescription
                requestShowSummaryTab = false
            }
            summaryProgress.summaryGeneration = .failed(error.localizedDescription)
            summaryProgress.vaultExport = .skipped
            summaryProgress.googleDocsExport = .skipped
            if Self.shouldCaptureSummaryGenerationError(error) {
                ErrorReportingService.capture(error, context: ["source": "summaryGeneration"])
            }
        }

        if summaryGeneratingMeetingId == meetingId {
            summaryGeneratingMeetingId = nil
        }

        // 全完了後に自動で非表示
        if summaryProgress.isAllDone, let progressPresentationID {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeOut(duration: 0.3)) {
                summaryProgress.dismiss(ifCurrent: progressPresentationID)
            }
        }

        if let currentMeetingId {
            generatePendingBatchSummaryIfReady(meetingId: currentMeetingId)
        }
    }

    private func persistGoogleDocsFileId(
        _ fileId: String,
        meetingId: UUID,
        dbQueue: DatabaseQueue?
    ) throws {
        if let dbQueue {
            try MeetingRepository(dbQueue: dbQueue)
                .updateSummaryGoogleFileId(forMeetingId: meetingId, googleFileId: fileId)
        }
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
        return try await GoogleDocsSummaryExportService.exportSummary(
            document: document,
            context: context,
            fileName: fileName
        )
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
        case .helperNotBundled, .notLoggedIn, .requestTimedOut, .turnInterrupted:
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

    func clearText() async {
        guard !isFinalizingRecording else { return }

        store.clear()
        await transcriptionEventPipeline?.resetPersistence()
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

    func takeScreenshot() {
        guard let meetingId = activeMeetingIdForSessionControls,
              let dbQueue = activeDbQueueForSessionControls,
              screenshotCaptureSource.isSelected else { return }

        let shouldRefreshVisibleScreenshots = currentMeetingId == meetingId

        Task {
            do {
                let cgImage = try await captureScreenshotImage()
                try await persistScreenshot(
                    cgImage,
                    meetingId: meetingId,
                    sessionId: persistenceService?.recordingSessionId,
                    dbQueue: dbQueue,
                    shouldRefreshVisibleScreenshots: shouldRefreshVisibleScreenshots
                )
                await updateAutomaticScreenshotFingerprintIfNeeded(for: cgImage)
            } catch {
                errorMessage = L10n.screenshotCaptureFailed(error.localizedDescription)
            }
        }
    }

    private func handleAutomaticScreenshotSettingsChange() {
        syncAutomaticScreenshotCaptureState()
    }

    private func handleAutomaticScreenshotIntervalChange() {
        guard automaticScreenshotTask != nil else { return }
        automaticScreenshotTask?.cancel()
        automaticScreenshotTask = nil
        if isListening, AppSettings.shared.automaticScreenshotEnabled, screenshotCaptureSource.isSelected {
            startAutomaticScreenshotCapture(resetFingerprint: false)
        } else {
            lastSavedAutomaticScreenshotFingerprint = nil
        }
    }

    private func handleScreenshotCaptureSourceChange() {
        guard isListening, AppSettings.shared.automaticScreenshotEnabled, screenshotCaptureSource.isSelected else {
            stopAutomaticScreenshotCapture()
            return
        }
        automaticScreenshotTask?.cancel()
        automaticScreenshotTask = nil
        startAutomaticScreenshotCapture()
    }

    private func syncAutomaticScreenshotCaptureState() {
        if isListening, AppSettings.shared.automaticScreenshotEnabled, screenshotCaptureSource.isSelected {
            startAutomaticScreenshotCapture()
        } else {
            stopAutomaticScreenshotCapture()
        }
    }

    private func startAutomaticScreenshotCapture(resetFingerprint: Bool = true) {
        guard automaticScreenshotTask == nil else { return }
        if resetFingerprint {
            lastSavedAutomaticScreenshotFingerprint = nil
        }
        automaticScreenshotTask = Task { [weak self] in
            await self?.runAutomaticScreenshotLoop()
        }
    }

    private func stopAutomaticScreenshotCapture() {
        automaticScreenshotTask?.cancel()
        automaticScreenshotTask = nil
        lastSavedAutomaticScreenshotFingerprint = nil
    }

    private func runAutomaticScreenshotLoop() async {
        while !Task.isCancelled {
            await captureAutomaticScreenshotIfNeeded()

            let intervalSeconds = max(1, AppSettings.shared.automaticScreenshotIntervalSeconds)
            do {
                try await Task.sleep(nanoseconds: UInt64(intervalSeconds) * 1_000_000_000)
            } catch {
                break
            }
        }
    }

    private func captureAutomaticScreenshotIfNeeded() async {
        guard isListening,
              AppSettings.shared.automaticScreenshotEnabled,
              screenshotCaptureSource.isSelected,
              let meetingId = activeMeetingIdForSessionControls,
              let dbQueue = activeDbQueueForSessionControls
        else {
            return
        }

        let shouldRefreshVisibleScreenshots = currentMeetingId == meetingId

        do {
            let cgImage = try await captureScreenshotImage()
            guard !Task.isCancelled,
                  isListening,
                  AppSettings.shared.automaticScreenshotEnabled,
                  screenshotCaptureSource.isSelected
            else { return }
            guard let fingerprint = await screenshotFingerprint(for: cgImage) else { return }
            let changeThresholdRatio = AppSettings.shared.automaticScreenshotChangeThresholdRatio

            let shouldSave = lastSavedAutomaticScreenshotFingerprint.map {
                ScreenshotChangeDetector.isSignificantlyDifferent(
                    $0,
                    fingerprint,
                    changedPixelRatioThreshold: changeThresholdRatio
                )
            } ?? true

            guard shouldSave,
                  !Task.isCancelled,
                  isListening,
                  AppSettings.shared.automaticScreenshotEnabled,
                  screenshotCaptureSource.isSelected
            else { return }

            try await persistScreenshot(
                cgImage,
                meetingId: meetingId,
                sessionId: persistenceService?.recordingSessionId,
                dbQueue: dbQueue,
                shouldRefreshVisibleScreenshots: shouldRefreshVisibleScreenshots
            )
            lastSavedAutomaticScreenshotFingerprint = fingerprint
        } catch is CancellationError {
            return
        } catch {
            // ウィンドウの一時クローズや画面ロックなど一過性の失敗でループ全体を
            // 止めない。次の周期で再試行する。
            errorMessage = L10n.screenshotCaptureFailed(error.localizedDescription)
        }
    }

    private func captureScreenshotImage() async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let filter = try screenshotContentFilter(from: content)
        let config = SCScreenshotConfiguration()
        config.showsCursor = false
        config.dynamicRange = .sdr

        // 対象の実サイズに合わせて ScreenCaptureKit に出力サイズを決めさせる。
        // `window.frame * 2` のような固定スケールは、非 Retina の拡張モニタで余白を生む。
        let output = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: config)
        guard let cgImage = output.sdrImage else {
            throw ScreenshotError.imageUnavailable
        }
        return cgImage
    }

    private func screenshotContentFilter(from content: SCShareableContent) throws -> SCContentFilter {
        switch screenshotCaptureSource {
        case .none:
            throw ScreenshotError.sourceUnavailable
        case .entireDesktop:
            guard let display = content.displays.first else {
                throw ScreenshotError.displayUnavailable
            }
            return SCContentFilter(display: display, excludingWindows: [])
        case let .window(windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw ScreenshotError.sourceUnavailable
            }
            return SCContentFilter(desktopIndependentWindow: window)
        }
    }

    private func persistScreenshot(
        _ cgImage: CGImage,
        meetingId: UUID,
        sessionId: UUID?,
        dbQueue: DatabaseQueue,
        shouldRefreshVisibleScreenshots: Bool
    ) async throws {
        let imageData: Data = try await Task.detached(priority: .userInitiated) {
            guard let encoded = ImageEncoder.encode(cgImage, quality: 0.70) else {
                throw ScreenshotError.encodingFailed
            }
            return encoded
        }.value

        let record = MeetingScreenshotRecord(
            id: UUID.v7(),
            meetingId: meetingId,
            sessionId: sessionId,
            capturedAt: Date(),
            imageData: imageData,
            mimeType: ImageEncoder.preferredMIMEType
        )

        try await dbQueue.write { db in
            try record.insert(db)
        }
        if shouldRefreshVisibleScreenshots {
            appendVisibleScreenshot(record)
        }
    }

    private func updateAutomaticScreenshotFingerprintIfNeeded(for cgImage: CGImage) async {
        guard automaticScreenshotTask != nil,
              let fingerprint = await screenshotFingerprint(for: cgImage) else { return }
        lastSavedAutomaticScreenshotFingerprint = fingerprint
    }

    private func screenshotFingerprint(for cgImage: CGImage) async -> ScreenshotFingerprint? {
        await Task.detached(priority: .utility) {
            ScreenshotChangeDetector.fingerprint(for: cgImage)
        }.value
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

    private func appendVisibleScreenshot(_ screenshot: MeetingScreenshotRecord) {
        guard currentMeetingId == screenshot.meetingId else { return }
        if let index = screenshots.firstIndex(where: { $0.id == screenshot.id }) {
            screenshots[index] = screenshot
        } else {
            let insertIndex = screenshots.firstIndex { $0.capturedAt > screenshot.capturedAt } ?? screenshots.endIndex
            screenshots.insert(screenshot, at: insertIndex)
        }
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
                self.screenshots.removeAll { deletedIds.contains($0.id) }
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
        let text = store.exportAsText()
        guard !text.isEmpty else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "transcript_\(Self.fileDateFormatter.string(from: store.recordingStartTime ?? Date())).txt"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Pipeline Construction

    private func handleTranscriptionEvent(_ event: TranscriptionEvent) {
        guard let plan = activeTranscriptionPlan else { return }
        TranscriptionEventRouter.route(
            event,
            plan: plan,
            transcriptStore: activeTranscriptStore,
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

    private func controllerSourceConfiguration(
        for source: RecordingAudioSource,
        plan: TranscriptionSessionPlan? = nil
    ) -> RecordingSessionController.SourceConfiguration {
        let effectivePlan = plan ?? activeTranscriptionPlan
        return RecordingSessionController.SourceConfiguration(
            source: source,
            captureDeviceID: source == .microphone ? microphoneCaptureDeviceID : nil,
            captureBufferSize: effectivePlan?.recordsBatchAudio == true ? 1024 : 4096
        )
    }

    private func controllerSourceConfigurations(
        plan: TranscriptionSessionPlan
    ) -> [RecordingSessionController.SourceConfiguration] {
        enabledRecordingAudioSources.map { source in
            controllerSourceConfiguration(for: source, plan: plan)
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
            if let snapshot = await self.recordingSessionController.snapshot(),
               snapshot.sessionId == recordingSessionId {
                self.activeControllerSources = snapshot.enabledSources
            }
            if isFatal {
                self.stopListening()
            }
        }
    }

    private func handleLiveSubtitleSettingChange(isEnabled: Bool) {
        guard var plan = activeTranscriptionPlan,
              let recordingSessionId = activeRecordingSessionId else { return }
        guard plan.liveSubtitlesEnabled != isEnabled else { return }
        let previousValue = plan.liveSubtitlesEnabled

        switch recordingLifecycle {
        case let .starting(sessionId) where sessionId == recordingSessionId:
            plan.liveSubtitlesEnabled = isEnabled
            activeTranscriptionPlan = plan
            if isEnabled {
                liveCaptionStore.start(sessionId: recordingSessionId)
            } else {
                liveCaptionStore.clear()
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
        } else {
            liveCaptionStore.clear()
        }

        enqueueRecordingConfiguration { [weak self] _ in
            guard let self,
                  self.activeTranscriptionPlan?.liveSubtitlesEnabled == isEnabled else { return }
            do {
                let locale = self.resolvedSelectedLocale()
                let snapshot = try await self.recordingSessionController.setLiveSubtitlesEnabled(
                    isEnabled,
                    translateSegment: self.translationHandler(for: locale)
                )
                self.activeControllerSources = snapshot.enabledSources
            } catch {
                self.errorMessage = error.localizedDescription
                self.restoreLiveSubtitleSetting(
                    previousValue,
                    recordingSessionId: recordingSessionId
                )
            }
        }
    }

    private func restoreLiveSubtitleSetting(_ isEnabled: Bool, recordingSessionId: UUID) {
        guard activeRecordingSessionId == recordingSessionId,
              var plan = activeTranscriptionPlan else { return }
        plan.liveSubtitlesEnabled = isEnabled
        activeTranscriptionPlan = plan
        AppSettings.shared.liveSubtitleOverlayEnabled = isEnabled

        if isEnabled {
            liveCaptionStore.start(sessionId: recordingSessionId)
            if plan.persistsRealtimeTranscript {
                liveCaptionStore.seed(activeTranscriptStore.segments, sessionId: recordingSessionId)
            }
        } else {
            liveCaptionStore.clear()
        }
    }

    private func reconcileStartingPlan(
        _ initialPlan: TranscriptionSessionPlan,
        recordingSessionId: UUID
    ) async throws -> TranscriptionSessionPlan {
        var plan = initialPlan
        while recordingLifecycle == .starting(recordingSessionId) {
            let desiredValue = activeTranscriptionPlan?.liveSubtitlesEnabled
                ?? AppSettings.shared.liveSubtitleOverlayEnabled
            guard plan.liveSubtitlesEnabled != desiredValue else { return plan }

            try ensureSessionIsActive(recordingSessionId)
            guard activeTranscriptionPlan?.liveSubtitlesEnabled == desiredValue else { continue }

            plan.liveSubtitlesEnabled = desiredValue
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
                let locale = resolvedSelectedLocale()
                let snapshot = try await recordingSessionController.setLiveSubtitlesEnabled(
                    latestPlan.liveSubtitlesEnabled,
                    translateSegment: translationHandler(for: locale)
                )
                activeControllerSources = snapshot.enabledSources
                appliedPlan = latestPlan
            }
            guard activeTranscriptionPlan?.liveSubtitlesEnabled == latestPlan.liveSubtitlesEnabled else {
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
                    isEnabled: AppSettings.shared.transcriptTranslationEnabled,
                    targetLanguageIdentifier: AppSettings.shared.transcriptTranslationTargetLanguage
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
        guard isSessionActive(recordingSessionId), !Task.isCancelled else {
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
