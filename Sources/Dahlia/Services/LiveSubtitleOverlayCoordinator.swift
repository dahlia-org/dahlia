import Combine
import Foundation

/// ウィンドウの表示状態に依存せずライブ字幕オーバーレイを同期する。
@MainActor
final class LiveSubtitleOverlayCoordinator {
    private let viewModel: CaptionViewModel
    private let liveSubtitleOverlayService: any LiveSubtitlePresenting

    private var viewModelCancellables: [AnyCancellable] = []
    private var storeCancellable: AnyCancellable?
    private var defaultsCancellables: [AnyCancellable] = []
    private var pendingStoreSyncTask: Task<Void, Never>?
    private var nextStoreSyncTime: ContinuousClock.Instant?

    init(viewModel: CaptionViewModel, liveSubtitleOverlayService: any LiveSubtitlePresenting) {
        self.viewModel = viewModel
        self.liveSubtitleOverlayService = liveSubtitleOverlayService
        bind()
        sync()
    }

    private func bind() {
        viewModelCancellables = [
            viewModel.$isListening.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in self?.sync() },
            viewModel.$activeTranscriptionMode.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in self?.sync() },
            viewModel.$appliedLiveRecognitionLocaleIdentifier.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in self?.sync() },
            viewModel.$transcriptionLocale.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in self?.sync() },
            viewModel.$liveSubtitleLocale.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in self?.sync() },
        ]

        storeCancellable = viewModel.liveCaptionStore.objectWillChange
            .receive(on: RunLoop.main)
            // Publish the newest partial caption at most five times per second.
            .sink { [weak self] _ in
                self?.scheduleStoreSync()
            }

        defaultsCancellables = [
            UserDefaults.standard.publisher(for: \.liveSubtitleOverlayEnabled).sink { [weak self] _ in self?.sync() },
            UserDefaults.standard.publisher(for: \.liveSubtitleOverlaySegmentCount).sink { [weak self] _ in self?.sync() },
            UserDefaults.standard.publisher(for: \.liveSubtitleSourceMode).sink { [weak self] _ in self?.sync() },
            UserDefaults.standard.publisher(for: \.transcriptTranslationEnabled).sink { [weak self] _ in self?.sync() },
            UserDefaults.standard.publisher(for: \.transcriptionLocale).sink { [weak self] _ in self?.sync() },
            UserDefaults.standard.publisher(for: \.liveSubtitleLocale).sink { [weak self] _ in self?.sync() },
            UserDefaults.standard.publisher(for: \.transcriptTranslationTargetLanguage).sink { [weak self] _ in self?.sync() },
        ]
    }

    private func scheduleStoreSync() {
        let clock = ContinuousClock()
        let now = clock.now
        guard let nextStoreSyncTime, now < nextStoreSyncTime else {
            pendingStoreSyncTask?.cancel()
            pendingStoreSyncTask = nil
            sync()
            self.nextStoreSyncTime = now.advanced(by: .milliseconds(200))
            return
        }
        guard pendingStoreSyncTask == nil else { return }

        pendingStoreSyncTask = Task { @MainActor [weak self] in
            try? await clock.sleep(until: nextStoreSyncTime)
            guard let self, !Task.isCancelled else { return }
            self.sync()
            self.nextStoreSyncTime = clock.now.advanced(by: .milliseconds(200))
            self.pendingStoreSyncTask = nil
        }
    }

    private func sync() {
        guard viewModel.isListening,
              AppSettings.shared.liveSubtitleOverlayEnabled else {
            liveSubtitleOverlayService.hide()
            return
        }

        let payload = LiveSubtitleOverlayPayload.history(
            from: viewModel.liveCaptionStore.segments,
            sourceMode: AppSettings.shared.liveSubtitleSourceMode,
            transcriptionLocaleIdentifier: viewModel.liveRecognitionLocaleIdentifier,
            translationEnabled: AppSettings.shared.transcriptTranslationEnabled,
            targetLanguageIdentifier: AppSettings.shared.transcriptTranslationTargetLanguage,
            visibleEntryCount: AppSettings.shared.liveSubtitleOverlaySegmentCount
        )

        liveSubtitleOverlayService.update(payload: payload)
    }
}
