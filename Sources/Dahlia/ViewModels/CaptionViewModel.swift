import Combine
import CoreAudio
import GRDB
import os
@preconcurrency import ScreenCaptureKit
import Speech
import SwiftUI

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
}

/// 音声キャプチャ → Speech フレームワーク文字起こし → UI 更新を統括するビューモデル。
@MainActor
final class CaptionViewModel: ObservableObject {

    // MARK: - Published State

    @Published var store = TranscriptStore() {
        didSet {
            bindStoreSegments()
        }
    }

    @Published var isListening = false
    @Published var isFinalizingRecording = false
    @Published var analyzerReady = false
    @Published var isPreparingAnalyzer = false
    @Published var errorMessage: String?
    @Published var availableMicrophones: [MicrophoneDevice] = []
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
    @Published var summaryError: String?
    @Published var summaryWarning: String?
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
        return !currentSummaryDocument.sections.isEmpty
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

    /// 録音中でなく、文字起こしを表示中の場合 true。
    var isViewingHistory: Bool {
        !isListening && currentMeetingId != nil
    }

    var selectedMicrophoneID: AudioDeviceID? {
        microphoneSelection.resolvedDeviceID(defaultDeviceID: defaultInputDeviceIDProvider())
    }

    var systemDefaultMicrophoneTitle: String {
        guard let defaultDeviceID = defaultInputDeviceIDProvider(),
              let deviceName = availableMicrophones.first(where: { $0.id == defaultDeviceID })?.name else {
            return L10n.sameAsSystem
        }
        return L10n.sameAsSystem(deviceName)
    }

    /// マイクが有効か。
    var isMicEnabled: Bool { selectedMicrophoneID != nil }

    /// 少なくとも 1 つの音声ソースが有効か。
    var hasEnabledAudioSource: Bool { isMicEnabled || isSystemAudioEnabled }

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
    private var audioManager: AudioCaptureManager?
    private var systemAudioManager: SystemAudioCaptureManager?
    private var pipelines: [(service: SpeechTranscriberService, bridge: AudioBufferBridge)] = []
    private var persistenceService: MeetingPersistenceService?
    private var settingsCancellable: AnyCancellable?
    private var storeSegmentsCancellable: AnyCancellable?
    private var transcriptionLocaleCancellable: AnyCancellable?
    private var automaticScreenshotSettingsCancellables: Set<AnyCancellable> = []
    private var automaticScreenshotTask: Task<Void, Never>?
    private var lastSavedAutomaticScreenshotFingerprint: ScreenshotFingerprint?
    private var meetingLoadTask: Task<Void, Never>?
    private var screenshotReloadGeneration = 0
    private var isSynchronizingSelectedLocale = false
    private let availableInputDevicesProvider: @Sendable () -> [MicrophoneDevice]
    private let defaultInputDeviceIDProvider: @Sendable () -> AudioDeviceID?
    private let transcriptTranslationService = TranscriptTranslationService()

    private nonisolated static let preferredTranscriptionLocaleFallbacksByLanguage = [
        "en": "en_US",
        "ja": "ja_JP",
    ]

    private var activeDbQueueForSessionControls: DatabaseQueue? {
        recordingContext?.dbQueue ?? currentDbQueue
    }

    init(
        availableInputDevicesProvider: @escaping @Sendable () -> [MicrophoneDevice] = AudioCaptureManager.availableInputDevices,
        defaultInputDeviceIDProvider: @escaping @Sendable () -> AudioDeviceID? = AudioCaptureManager.defaultInputDeviceID
    ) {
        self.availableInputDevicesProvider = availableInputDevicesProvider
        self.defaultInputDeviceIDProvider = defaultInputDeviceIDProvider
        bindStoreSegments()
        refreshAvailableMicrophones()

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

    func refreshAvailableMicrophones() {
        let devices = availableInputDevicesProvider()

        if devices != availableMicrophones {
            availableMicrophones = devices
        }

        if case let .device(currentMicrophoneID) = microphoneSelection,
           !devices.contains(where: { $0.id == currentMicrophoneID }) {
            microphoneSelection = .systemDefault
        }
    }

    private static let fileDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f
    }()

    private struct LoadedMeetingData {
        let createdAt: Date?
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
        projectURL: URL?,
        vaultURL: URL
    ) throws -> LoadedMeetingData {
        let repo = MeetingRepository(dbQueue: dbQueue)
        let detail = try repo.fetchMeetingDetail(id: meetingId)
        let recordingSessions = detail.recordingSessions.map(RecordingSessionTimeline.init)
        let segments = detail.segments.map(TranscriptSegment.init(from:))

        let lastSummaryURL = SummaryService.findSummaryFile(
            projectURL: projectURL,
            vaultURL: vaultURL,
            meetingId: meetingId
        )

        return LoadedMeetingData(
            createdAt: detail.meeting?.createdAt,
            recordingSessions: recordingSessions,
            segments: segments,
            screenshots: detail.screenshots,
            summaryDocument: detail.summary?.loadDocument(),
            googleFileId: detail.summary?.googleFileId,
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

        meetingLoadTask = Task { [weak self, meetingId, dbQueue, projectURL, vaultURL] in
            guard let self else { return }

            let loaded: LoadedMeetingData
            do {
                loaded = try await Task.detached(priority: .userInitiated) {
                    try Self.fetchLoadedMeetingData(
                        meetingId: meetingId,
                        dbQueue: dbQueue,
                        projectURL: projectURL,
                        vaultURL: vaultURL
                    )
                }.value
            } catch is CancellationError {
                return
            } catch {
                Logger(subsystem: "com.dahlia", category: "CaptionViewModel")
                    .error("Failed to load meeting \(meetingId): \(error)")
                ErrorReportingService.capture(error, context: ["source": "loadMeeting"])
                return
            }

            guard !Task.isCancelled, self.currentMeetingId == meetingId else { return }

            self.store.recordingStartTime = loaded.createdAt
            self.store.loadRecordingSessions(loaded.recordingSessions)
            self.store.loadSegments(loaded.segments)
            self.applyLoadedDetail(loaded)
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

        let resolvedProjectURL = projectURL ?? draftMeeting.projectURL ?? currentProjectURL
        let resolvedProjectId = projectId ?? draftMeeting.projectId ?? currentProjectId
        let resolvedProjectName = projectName ?? draftMeeting.projectName ?? currentProjectName
        let meetingId = UUID.v7()
        let now = Date()
        let record = MeetingRecord(
            id: meetingId,
            vaultId: vault.id,
            projectId: resolvedProjectId,
            name: draftMeeting.title.trimmingCharacters(in: .whitespacesAndNewlines),
            status: .transcriptNotFound,
            duration: nil,
            createdAt: now,
            updatedAt: now
        )
        do {
            try dbQueue.write { db in
                try record.insert(db)
                if let event = draftMeeting.linkedCalendarEvent {
                    try CalendarEventRecord(meetingId: meetingId, now: now, event: event).insert(db)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            ErrorReportingService.capture(error, context: ["source": "materializeDraftMeeting"])
            return nil
        }

        setMeetingContext(
            id: meetingId,
            dbQueue: dbQueue,
            projectURL: resolvedProjectURL,
            projectId: resolvedProjectId,
            projectName: resolvedProjectName,
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
        let projectURL = currentProjectURL
        meetingLoadTask = Task { [weak self, meetingId, dbQueue, projectURL, vaultURL] in
            guard let self else { return }
            let loaded: LoadedMeetingData
            do {
                loaded = try await Task.detached(priority: .userInitiated) {
                    try Self.fetchLoadedMeetingData(
                        meetingId: meetingId,
                        dbQueue: dbQueue,
                        projectURL: projectURL,
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
        setupNoteAutoSave()
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
            dbQueue: currentDbQueue
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
    }

    private func resetSummaryState() {
        currentSummaryDocument = nil
        currentSummaryGoogleFileId = nil
        lastSummaryURL = nil
        requestShowSummaryTab = false
        summaryError = nil
        summaryWarning = nil
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

    func updateCurrentProjectContext(projectURL: URL?, projectId: UUID?, projectName: String?) {
        currentProjectURL = projectURL
        currentProjectId = projectId
        currentProjectName = projectName
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
        applyAudioSourceSelectionChange { self.microphoneSelection = oldSelection }
    }

    func handleSystemAudioSelectionChange(from oldValue: Bool, to newValue: Bool) {
        guard oldValue != newValue else { return }
        applyAudioSourceSelectionChange { self.isSystemAudioEnabled = oldValue }
    }

    private func applyLocaleChange(from oldLocale: String, to newLocale: String) {
        guard newLocale != oldLocale || !analyzerReady else { return }
        AppSettings.shared.transcriptionLocale = newLocale

        if isListening {
            Task { await rebuildPipelines(reason: .localeChange) }
        } else {
            analyzerReady = false
            pipelines.removeAll()
            prepareAnalyzer()
        }
    }

    private func applyAudioSourceSelectionChange(restoreSelection: @escaping @MainActor () -> Void) {
        guard isListening else { return }

        Task { @MainActor in
            let applied = await rebuildPipelines(reason: .audioSourceChange)
            if !applied {
                restoreSelection()
            }
        }
    }

    private enum PipelineRebuildReason {
        case localeChange
        case audioSourceChange
    }

    @discardableResult
    private func rebuildPipelines(reason: PipelineRebuildReason) async -> Bool {
        await stopActivePipelines()
        stopActiveCaptures()

        let primaryLocale = resolvedSelectedLocale()
        do {
            try await SpeechTranscriberService.ensureModelInstalled(locale: primaryLocale)
        } catch {
            setPipelineRebuildError(error, reason: reason)
            return false
        }

        var sourceErrors: [Error] = []
        let recordingStartTime = Date()
        let recordingSessionId = persistenceService?.recordingSessionId ?? UUID.v7()

        if isMicEnabled {
            do {
                try await startMicrophonePipeline(
                    locale: primaryLocale,
                    recordingStartTime: recordingStartTime,
                    recordingSessionId: recordingSessionId
                )
            } catch {
                sourceErrors.append(error)
            }
        }

        if isSystemAudioEnabled {
            do {
                try await startSystemAudioPipeline(
                    locale: primaryLocale,
                    recordingStartTime: recordingStartTime,
                    recordingSessionId: recordingSessionId
                )
            } catch {
                sourceErrors.append(error)
            }
        }

        analyzerReady = true
        if let firstError = sourceErrors.first {
            setPipelineRebuildError(firstError, reason: reason)
            return false
        }

        errorMessage = nil
        return true
    }

    private func setPipelineRebuildError(_ error: Error, reason: PipelineRebuildReason) {
        switch reason {
        case .localeChange:
            errorMessage = L10n.languageChangeFailed(error.localizedDescription)
        case .audioSourceChange:
            errorMessage = error.localizedDescription
        }
    }

    private func stopActiveCaptures() {
        audioManager?.onAudioBuffer = nil
        audioManager?.stopCapture()
        audioManager = nil

        systemAudioManager?.onAudioBuffer = nil
        systemAudioManager?.onStreamStopped = nil
        systemAudioManager?.stopCapture()
        systemAudioManager = nil
    }

    private func stopActivePipelines() async {
        for pipeline in pipelines {
            pipeline.bridge.finish()
            await pipeline.service.stopStreaming()
        }
        pipelines.removeAll()
    }

    private func startMicrophonePipeline(locale: Locale, recordingStartTime: Date, recordingSessionId: UUID) async throws {
        let hasMicPermission = await AudioCaptureManager.requestMicrophonePermission()
        guard hasMicPermission else {
            throw AudioCaptureError.microphonePermissionDenied
        }

        let (service, bridge, format) = try await buildPipeline(
            locale: locale,
            speakerLabel: "mic",
            recordingStartTime: recordingStartTime,
            recordingSessionId: recordingSessionId
        )
        try startMicrophoneCapture(
            bridge: bridge,
            targetFormat: format,
            selectedDeviceID: selectedMicrophoneID
        )
        pipelines.append((service: service, bridge: bridge))
    }

    private func startSystemAudioPipeline(locale: Locale, recordingStartTime: Date, recordingSessionId: UUID) async throws {
        let (service, bridge, format) = try await buildPipeline(
            locale: locale,
            speakerLabel: "system",
            recordingStartTime: recordingStartTime,
            recordingSessionId: recordingSessionId
        )
        try await startSystemAudioCapture(bridge: bridge, targetFormat: format)
        pipelines.append((service: service, bridge: bridge))
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

        if isListening {
            stopListening()
        } else {
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
        guard !isListening, !isFinalizingRecording else { return }

        self.currentProjectURL = projectURL
        self.currentProjectId = projectId
        self.currentProjectName = projectName
        self.currentVaultURL = vaultURL
        self.currentDbQueue = dbQueue
        resetSummaryState()
        let activeDraftMeeting = draftMeeting
        guard analyzerReady else {
            errorMessage = L10n.speechRecognitionNotReady
            return
        }

        guard hasEnabledAudioSource else {
            errorMessage = L10n.noAudioSourceSelected
            return
        }

        pipelines.removeAll()
        let recordingStartTime = Date()
        let recordingSessionId = UUID.v7()
        let appendContext: MeetingRepository.AppendRecordingContext?
        if let existingMeetingId {
            let repo = MeetingRepository(dbQueue: dbQueue)
            appendContext = try? repo.fetchAppendRecordingContext(forMeetingId: existingMeetingId)
            if let recordingSessions = appendContext?.recordingSessions, !recordingSessions.isEmpty {
                store.loadRecordingSessions(recordingSessions.map(RecordingSessionTimeline.init))
            }
            if store.recordingStartTime == nil {
                if let firstSegmentStartTime = appendContext?.firstSegmentStartTime {
                    store.recordingStartTime = appendContext?.meetingCreatedAt ?? firstSegmentStartTime
                } else {
                    store.recordingStartTime = recordingStartTime
                    try? repo.updateMeetingCreatedAt(id: existingMeetingId, createdAt: recordingStartTime)
                }
            }
        } else {
            appendContext = nil
            store.recordingStartTime = recordingStartTime
        }
        persistenceService = nil
        stopAutomaticScreenshotCapture()

        do {
            let primaryLocale = resolvedSelectedLocale()
            try await SpeechTranscriberService.ensureModelInstalled(locale: primaryLocale)

            if isMicEnabled {
                try await startMicrophonePipeline(
                    locale: primaryLocale,
                    recordingStartTime: recordingStartTime,
                    recordingSessionId: recordingSessionId
                )
            }
            if isSystemAudioEnabled {
                try await startSystemAudioPipeline(
                    locale: primaryLocale,
                    recordingStartTime: recordingStartTime,
                    recordingSessionId: recordingSessionId
                )
            }

            if let existingMeetingId {
                // 追記モード: 既存セグメント ID を取得して PersistenceService に渡す
                persistenceService = try MeetingPersistenceService(
                    store: store,
                    dbQueue: dbQueue,
                    existingMeetingId: existingMeetingId,
                    existingSegmentIds: appendContext?.segmentIds ?? [],
                    recordingStartDate: recordingStartTime,
                    recordingOffsetSeconds: appendContext?.nextOffsetSeconds ?? 0,
                    recordingSessionId: recordingSessionId
                )
                currentMeetingId = existingMeetingId
            } else {
                let initialName = activeDraftMeeting?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                persistenceService = try MeetingPersistenceService(
                    store: store,
                    dbQueue: dbQueue,
                    vaultId: vaultId,
                    projectId: projectId,
                    initialName: initialName,
                    calendarEvent: activeDraftMeeting?.linkedCalendarEvent,
                    recordingSessionId: recordingSessionId
                )
                currentMeetingId = persistenceService?.meetingId
                draftMeeting = nil
                setupNoteAutoSave()
                saveNoteImmediately()
            }

            self.isListening = true
            self.errorMessage = nil
            syncAutomaticScreenshotCaptureState()
        } catch {
            self.errorMessage = error.localizedDescription
            ErrorReportingService.capture(error, context: ["source": "startListening"])
            await stopActivePipelines()
            stopActiveCaptures()
            stopAutomaticScreenshotCapture()
            persistenceService = nil
            if existingMeetingId == nil {
                currentMeetingId = nil
            }
        }
    }

    func stopListening() {
        guard isListening, !isFinalizingRecording else { return }

        isFinalizingRecording = true
        stopAutomaticScreenshotCapture()
        stopActiveCaptures()
        isListening = false

        // ナビゲーション済みの場合、録音コンテキストからデータを取得
        let ctx = recordingContext
        let activeStore = ctx?.store ?? store
        let meetingId = ctx?.meetingId ?? currentMeetingId
        let projectName = ctx?.projectName ?? selectedProjectName
        let vaultURL = ctx?.vaultURL ?? currentVaultURL
        let recordingStart = activeStore.timeBase
        recordingContext = nil

        Task {
            await stopActivePipelines()
            persistenceService?.stop()
            persistenceService = nil
            let segments = activeStore.segments
            let recordingSessions = activeStore.recordingSessions
            isFinalizingRecording = false

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

    /// 現在選択中のプロジェクト名。
    private var selectedProjectName: String? {
        currentProjectName ?? currentProjectURL?.lastPathComponent
    }

    // MARK: - Summary Generation

    /// 手動で要約を実行できるかどうか。
    var canGenerateSummary: Bool {
        guard !isListening,
              !isFinalizingRecording,
              currentMeetingId != nil,
              currentVaultURL != nil else { return false }
        return !store.segments.isEmpty
    }

    /// プルダウンメニューから手動で要約を実行する。
    func triggerManualSummary() {
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
                recordingSessions: recordingSessions
            )
        }
    }

    func generateSummary(
        meetingId: UUID,
        transcriptText: String,
        projectURL: URL?,
        createdAt: Date,
        vaultURL: URL,
        projectName: String,
        segments: [TranscriptSegment],
        recordingSessions: [RecordingSessionTimeline]
    ) async {
        guard !transcriptText.isEmpty else { return }

        guard AppSettings.shared.isLLMConfigComplete else {
            summaryError = L10n.llmConfigIncomplete
            return
        }

        // 要約前にノートを即座に保存してから取得
        saveNoteImmediately()
        let currentNoteText = noteText

        summaryGeneratingMeetingId = meetingId
        summaryError = nil
        summaryWarning = nil
        lastSummaryURL = nil

        do {
            let dbQueue = currentDbQueue
            let projectId = currentProjectId
            let repo = dbQueue.map { MeetingRepository(dbQueue: $0) }
            var screenshots: [MeetingScreenshotRecord] = []
            var googleDriveFolderId: String?
            if let repo {
                screenshots = (try? repo.fetchScreenshots(forMeetingId: meetingId)) ?? []
                if let projectId,
                   let project = try repo.fetchProject(id: projectId),
                   let folderId = project.googleDriveFolderId?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !folderId.isEmpty {
                    googleDriveFolderId = folderId
                }
            }

            summaryProgress.show()
            if googleDriveFolderId != nil {
                summaryProgress.driveExport = .pending
            }

            // LLM 要約
            summaryProgress.summaryGeneration = .running

            let generatedSummary = try await SummaryService.generateSummary(
                projectURL: projectURL,
                meetingId: meetingId,
                createdAt: createdAt,
                transcriptText: transcriptText,
                noteText: currentNoteText.isEmpty ? nil : currentNoteText,
                screenshots: screenshots,
                recordingSessions: recordingSessions,
                repository: repo
            )

            if let repo {
                try repo.applyGeneratedSummary(
                    toMeetingId: meetingId,
                    document: generatedSummary.document,
                    renderedBody: generatedSummary.renderedBody,
                    tags: generatedSummary.document.tags
                )
            }
            summaryProgress.summaryGeneration = .completed
            if currentMeetingId == meetingId {
                currentSummaryDocument = generatedSummary.document
            }

            summaryProgress.vaultExport = .running
            if googleDriveFolderId != nil {
                summaryProgress.driveExport = .running
            }

            async let vaultExport: URL = VaultSummaryExportService.exportSummaryBundle(
                projectURL: projectURL,
                vaultURL: vaultURL,
                meetingId: meetingId,
                createdAt: createdAt,
                projectName: projectName,
                segments: segments,
                recordingSessions: recordingSessions,
                screenshots: screenshots,
                summaryFileName: generatedSummary.fileName,
                summaryMarkdown: generatedSummary.markdown
            )
            let driveExportTask: Task<String, Error>? = if let googleDriveFolderId {
                Task<String, Error> {
                    try await GoogleDriveSummaryExportService.exportSummary(
                        folderId: googleDriveFolderId,
                        meetingId: meetingId,
                        projectId: projectId,
                        fileName: generatedSummary.fileName,
                        markdown: generatedSummary.markdown
                    )
                }
            } else {
                nil
            }

            do {
                let fileURL = try await vaultExport
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

            do {
                if let driveExportTask {
                    let fileId = try await driveExportTask.value
                    try repo?.updateSummaryGoogleFileId(forMeetingId: meetingId, googleFileId: fileId)
                    summaryProgress.driveExport = .completed
                    if currentMeetingId == meetingId {
                        currentSummaryGoogleFileId = fileId
                    }
                }
            } catch {
                let warning = GoogleAuthErrorFormatter.message(
                    for: error,
                    defaultMessage: L10n.googleDriveExportFailed
                )
                summaryWarning = warning
                summaryProgress.driveExport = .failed(warning)
            }
        } catch {
            if currentMeetingId == meetingId {
                summaryError = error.localizedDescription
                requestShowSummaryTab = false
            }
            summaryProgress.summaryGeneration = .failed(error.localizedDescription)
            summaryProgress.vaultExport = .skipped
            if summaryProgress.driveExport != nil {
                summaryProgress.driveExport = .skipped
            }
            ErrorReportingService.capture(error, context: ["source": "summaryGeneration"])
        }

        if summaryGeneratingMeetingId == meetingId {
            summaryGeneratingMeetingId = nil
        }

        // 全完了後に自動で非表示
        if summaryProgress.isAllDone {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeOut(duration: 0.3)) {
                summaryProgress.dismiss()
            }
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

    func clearText() {
        guard !isFinalizingRecording else { return }

        store.clear()
        persistenceService?.reset()
        Task {
            for pipeline in pipelines {
                await pipeline.service.reset()
            }
        }
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
            Logger(subsystem: "com.dahlia", category: "CaptionViewModel")
                .error("Failed to save note: \(error)")
        }
    }

    private func saveNoteImmediately() {
        guard hasNote || !noteText.isEmpty,
              noteText != lastSavedNoteText else { return }
        saveNote(text: noteText)
    }

    /// DB からスクリーンショット一覧を再読み込みする。
    func reloadScreenshots() {
        screenshotReloadGeneration += 1
        let generation = screenshotReloadGeneration

        guard let meetingId = currentMeetingId,
              let dbQueue = currentDbQueue else {
            screenshots = []
            return
        }
        Task { [weak self, meetingId, dbQueue] in
            let screenshots = await Task.detached(priority: .userInitiated) {
                let repo = MeetingRepository(dbQueue: dbQueue)
                return (try? repo.fetchScreenshots(forMeetingId: meetingId)) ?? []
            }.value
            guard let self,
                  self.currentMeetingId == meetingId,
                  self.screenshotReloadGeneration == generation else { return }
            self.screenshots = screenshots
        }
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
        guard let dbQueue = activeDbQueueForSessionControls else { return }
        let repo = MeetingRepository(dbQueue: dbQueue)
        try? repo.deleteScreenshot(id: screenshot.id)
        if currentMeetingId == screenshot.meetingId {
            reloadScreenshots()
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

    private func buildPipeline(
        locale: Locale,
        speakerLabel: String,
        recordingStartTime: Date,
        recordingSessionId: UUID
    ) async throws -> (service: SpeechTranscriberService, bridge: AudioBufferBridge, format: AVAudioFormat) {
        let service = SpeechTranscriberService(
            locale: locale,
            speakerLabel: speakerLabel,
            translateSegment: translationHandler(for: locale)
        )
        try await service.prepare()
        guard let format = await service.targetAudioFormat() else {
            throw AudioCaptureError.converterCreationFailed
        }
        let bridge = AudioBufferBridge(sampleRate: format.sampleRate)
        try await service.startStreaming(
            store: store,
            bridge: bridge,
            recordingStartTime: recordingStartTime,
            recordingSessionId: recordingSessionId
        )
        return (service: service, bridge: bridge, format: format)
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

    private func startMicrophoneCapture(
        bridge: AudioBufferBridge,
        targetFormat: AVAudioFormat,
        selectedDeviceID: AudioDeviceID?
    ) throws {
        let manager = AudioCaptureManager()
        manager.onAudioBuffer = { [bridge] buffer in
            bridge.appendBuffer(buffer)
        }
        try manager.startCapture(targetFormat: targetFormat, selectedDeviceID: selectedDeviceID)
        self.audioManager = manager
    }

    private func startSystemAudioCapture(bridge: AudioBufferBridge, targetFormat: AVAudioFormat) async throws {
        let hasPermission = await SystemAudioCaptureManager.requestPermission()
        guard hasPermission else {
            throw SystemAudioCaptureError.screenRecordingPermissionDenied
        }

        let manager = SystemAudioCaptureManager()
        manager.onAudioBuffer = { [bridge] buffer in
            bridge.appendBuffer(buffer)
        }
        manager.onStreamStopped = { [weak self] error in
            Task { @MainActor in
                self?.errorMessage = error?.localizedDescription ?? L10n.systemAudioCaptureStopped
                if self?.audioManager == nil {
                    self?.isListening = false
                }
            }
        }
        try await manager.startCapture(targetFormat: targetFormat)
        self.systemAudioManager = manager
    }
}
