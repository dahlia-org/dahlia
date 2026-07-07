import Combine
import Foundation

/// ウィンドウの表示状態に依存せずライブ字幕オーバーレイを同期する。
@MainActor
final class LiveSubtitleOverlayCoordinator {
    private let viewModel: CaptionViewModel
    private let liveSubtitleOverlayService: LiveSubtitleOverlayService

    private var viewModelCancellable: AnyCancellable?
    private var storeCancellable: AnyCancellable?
    private var defaultsCancellables: [AnyCancellable] = []
    private var activeStoreIdentifier: ObjectIdentifier?

    init(viewModel: CaptionViewModel, liveSubtitleOverlayService: LiveSubtitleOverlayService) {
        self.viewModel = viewModel
        self.liveSubtitleOverlayService = liveSubtitleOverlayService
        bind()
        sync()
    }

    private func bind() {
        viewModelCancellable = viewModel.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.bindActiveStoreIfNeeded()
                self.sync()
            }

        bindActiveStoreIfNeeded()

        defaultsCancellables = [
            UserDefaults.standard.publisher(for: \.liveSubtitleOverlayEnabled).sink { [weak self] _ in self?.sync() },
            UserDefaults.standard.publisher(for: \.liveSubtitleOverlaySegmentCount).sink { [weak self] _ in self?.sync() },
            UserDefaults.standard.publisher(for: \.liveSubtitleSourceMode).sink { [weak self] _ in self?.sync() },
            UserDefaults.standard.publisher(for: \.transcriptTranslationEnabled).sink { [weak self] _ in self?.sync() },
            UserDefaults.standard.publisher(for: \.transcriptionLocale).sink { [weak self] _ in self?.sync() },
            UserDefaults.standard.publisher(for: \.transcriptTranslationTargetLanguage).sink { [weak self] _ in self?.sync() },
        ]
    }

    private func bindActiveStoreIfNeeded() {
        let store = viewModel.activeTranscriptStore
        let identifier = ObjectIdentifier(store)
        guard activeStoreIdentifier != identifier else { return }

        activeStoreIdentifier = identifier
        storeCancellable = store.objectWillChange
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.sync()
            }
    }

    private func sync() {
        bindActiveStoreIfNeeded()

        guard viewModel.isListening,
              AppSettings.shared.liveSubtitleOverlayEnabled else {
            liveSubtitleOverlayService.hide()
            return
        }

        let payload = LiveSubtitleOverlayPayload.latest(
            from: viewModel.activeTranscriptStore.segments,
            sourceMode: AppSettings.shared.liveSubtitleSourceMode,
            transcriptionLocaleIdentifier: AppSettings.shared.transcriptionLocale,
            translationEnabled: AppSettings.shared.transcriptTranslationEnabled,
            targetLanguageIdentifier: AppSettings.shared.transcriptTranslationTargetLanguage,
            maxEntries: max(1, AppSettings.shared.liveSubtitleOverlaySegmentCount)
        )

        liveSubtitleOverlayService.update(payload: payload)
    }
}
