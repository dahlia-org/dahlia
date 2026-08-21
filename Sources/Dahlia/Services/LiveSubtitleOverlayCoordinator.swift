import Combine
import Foundation

/// ウィンドウの表示状態に依存せずライブ字幕オーバーレイを同期する。
@MainActor
final class LiveSubtitleOverlayCoordinator {
    private let viewModel: CaptionViewModel
    private let liveSubtitleOverlayService: any LiveSubtitlePresenting
    private let payloadProjector = LiveSubtitleOverlayPayloadProjector()

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

        storeCancellable = viewModel.liveCaptionStore.overlayChanges
            .sink { [weak self] change in
                self?.applyStoreChange(change)
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

    private func applyStoreChange(_ change: LiveCaptionStore.OverlayChange) {
        payloadProjector.apply(change)
        if case .clearPreview = change {
            scheduleStoreSync(allowsImmediateSync: false)
        } else {
            scheduleStoreSync()
        }
    }

    private func scheduleStoreSync(allowsImmediateSync: Bool = true) {
        let clock = ContinuousClock()
        let now = clock.now
        if !allowsImmediateSync,
           nextStoreSyncTime.map({ now >= $0 }) ?? true {
            nextStoreSyncTime = now.advanced(by: .milliseconds(200))
        }
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
            payloadProjector.apply(.reload)
            liveSubtitleOverlayService.hide()
            return
        }

        let payload = payloadProjector.payload(
            from: viewModel.liveCaptionStore.segments,
            configuration: payloadConfiguration,
            visibleEntryCount: AppSettings.shared.liveSubtitleOverlaySegmentCount
        )

        liveSubtitleOverlayService.update(payload: payload)
    }

    private var payloadConfiguration: LiveSubtitleOverlayPayload.Configuration {
        LiveSubtitleOverlayPayload.Configuration(
            sourceMode: AppSettings.shared.liveSubtitleSourceMode,
            transcriptionLocaleIdentifier: viewModel.liveRecognitionLocaleIdentifier,
            translationEnabled: AppSettings.shared.liveSubtitleTranslationEnabled,
            targetLanguageIdentifier: AppSettings.shared.liveSubtitleTranslationTargetLanguage
        )
    }
}
