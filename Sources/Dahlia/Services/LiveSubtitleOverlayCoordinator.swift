import Combine
import Foundation

/// ウィンドウの表示状態に依存せずライブ字幕オーバーレイを同期する。
@MainActor
final class LiveSubtitleOverlayCoordinator {
    private let viewModel: CaptionViewModel
    private let liveSubtitleOverlayService: any LiveSubtitlePresenting

    private var viewModelCancellable: AnyCancellable?
    private var storeCancellable: AnyCancellable?
    private var defaultsCancellables: [AnyCancellable] = []

    init(viewModel: CaptionViewModel, liveSubtitleOverlayService: any LiveSubtitlePresenting) {
        self.viewModel = viewModel
        self.liveSubtitleOverlayService = liveSubtitleOverlayService
        bind()
        sync()
    }

    private func bind() {
        viewModelCancellable = viewModel.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.sync()
            }

        storeCancellable = viewModel.liveCaptionStore.objectWillChange
            // Publish the newest partial caption at most five times per second.
            // Unlike debounce, throttle keeps progressing during continuous speech.
            .throttle(for: .milliseconds(200), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                self?.sync()
            }

        defaultsCancellables = [
            UserDefaults.standard.publisher(for: \.liveSubtitleOverlayEnabled).sink { [weak self] _ in self?.sync() },
            UserDefaults.standard.publisher(for: \.liveSubtitleOverlaySegmentCount).sink { [weak self] _ in self?.sync() },
            UserDefaults.standard.publisher(for: \.liveSubtitleSourceMode).sink { [weak self] _ in self?.sync() },
            UserDefaults.standard.publisher(for: \.transcriptTranslationEnabled).sink { [weak self] _ in self?.sync() },
            UserDefaults.standard.publisher(for: \.transcriptionLocale).sink { [weak self] _ in self?.sync() },
            UserDefaults.standard.publisher(for: \.transcriptTranslationTargetLanguage).sink { [weak self] _ in self?.sync() },
        ]
    }

    private func sync() {
        guard viewModel.isListening,
              AppSettings.shared.liveSubtitleOverlayEnabled else {
            liveSubtitleOverlayService.hide()
            return
        }

        let sourceMode = AppSettings.shared.liveSubtitleSourceMode
        let payload = LiveSubtitleOverlayPayload.latest(
            from: viewModel.liveCaptionStore.segments,
            sourceMode: sourceMode,
            transcriptionLocaleIdentifier: AppSettings.shared.transcriptionLocale,
            translationEnabled: AppSettings.shared.transcriptTranslationEnabled,
            targetLanguageIdentifier: AppSettings.shared.transcriptTranslationTargetLanguage,
            maxEntries: max(1, AppSettings.shared.liveSubtitleOverlaySegmentCount)
        )

        // 字幕は有効で録音中のため、表示対象がまだ無くてもオーバーレイは隠さず待機表示にする。
        // これにより「字幕 ON なのにパネルすら出ない」状態を防ぐ。
        liveSubtitleOverlayService.update(payload: payload ?? .waiting(placeholderText: waitingText(for: sourceMode)))
    }

    private func waitingText(for sourceMode: LiveSubtitleSourceMode) -> String {
        switch sourceMode {
        case .systemAudioOnly:
            L10n.liveSubtitleWaitingForSystemAudio
        case .includeMicrophone:
            L10n.liveSubtitleWaitingForAudio
        }
    }
}
