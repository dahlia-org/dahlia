import Combine
import Foundation
import Observation

/// メニューバーを `CaptionViewModel` 全体の高頻度な更新から隔離する、限定的な UI projection。
@MainActor
@Observable
final class MenuBarRecordingState {
    @ObservationIgnored private let viewModel: CaptionViewModel
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []

    private(set) var isListening: Bool
    private(set) var microphoneSelection: MicrophoneSelection
    private(set) var isSystemAudioEnabled: Bool
    private(set) var transcriptionLocale: String
    private(set) var liveSubtitleLocale: String
    private(set) var liveRecognitionLocaleIdentifier: String
    private(set) var activeTranscriptionMode: TranscriptionMode?
    private(set) var availableMicrophones: [MicrophoneDevice]
    private(set) var filteredLocales: [Locale]
    private(set) var availableWindows: [ScreenshotWindowOption]
    private(set) var screenshotCaptureSource: ScreenshotCaptureSource
    private(set) var systemDefaultMicrophoneTitle: String
    private(set) var canBeginRecording: Bool

    init(viewModel: CaptionViewModel) {
        self.viewModel = viewModel
        isListening = viewModel.isListening
        microphoneSelection = viewModel.microphoneSelection
        isSystemAudioEnabled = viewModel.isSystemAudioEnabled
        transcriptionLocale = viewModel.transcriptionLocale
        liveSubtitleLocale = viewModel.liveSubtitleLocale
        liveRecognitionLocaleIdentifier = viewModel.liveRecognitionLocaleIdentifier
        activeTranscriptionMode = viewModel.activeTranscriptionMode
        availableMicrophones = viewModel.availableMicrophones
        filteredLocales = viewModel.filteredLocales
        availableWindows = viewModel.availableWindows
        screenshotCaptureSource = viewModel.screenshotCaptureSource
        systemDefaultMicrophoneTitle = viewModel.systemDefaultMicrophoneTitle
        canBeginRecording = viewModel.canBeginRecording

        observeMenuState()
    }

    func refreshAvailableMicrophones() async {
        await viewModel.refreshAvailableMicrophones()
    }

    func refreshAvailableWindows() {
        viewModel.refreshAvailableWindows()
    }

    func selectMicrophone(_ selection: MicrophoneSelection) {
        let oldSelection = viewModel.microphoneSelection
        guard selection != oldSelection else { return }
        viewModel.microphoneSelection = selection
        viewModel.handleMicrophoneSelectionChange(from: oldSelection, to: selection)
    }

    func setSystemAudioEnabled(_ isEnabled: Bool) {
        let oldValue = viewModel.isSystemAudioEnabled
        guard isEnabled != oldValue else { return }
        viewModel.isSystemAudioEnabled = isEnabled
        viewModel.handleSystemAudioSelectionChange(from: oldValue, to: isEnabled)
    }

    func selectLiveSubtitleLocale(_ localeIdentifier: String) {
        viewModel.selectLiveSubtitleLocale(localeIdentifier)
    }

    func selectScreenshotSource(_ source: ScreenshotCaptureSource) {
        guard source != viewModel.screenshotCaptureSource else { return }
        viewModel.screenshotCaptureSource = source
    }

    private func observeMenuState() {
        viewModel.$isListening
            .removeDuplicates()
            .sink { [weak self] in self?.isListening = $0 }
            .store(in: &cancellables)

        viewModel.$microphoneSelection
            .removeDuplicates()
            .sink { [weak self] in self?.microphoneSelection = $0 }
            .store(in: &cancellables)

        viewModel.$isSystemAudioEnabled
            .removeDuplicates()
            .sink { [weak self] in self?.isSystemAudioEnabled = $0 }
            .store(in: &cancellables)

        viewModel.$transcriptionLocale
            .removeDuplicates()
            .sink { [weak self] in self?.transcriptionLocale = $0 }
            .store(in: &cancellables)

        viewModel.$liveSubtitleLocale
            .removeDuplicates()
            .sink { [weak self] in self?.liveSubtitleLocale = $0 }
            .store(in: &cancellables)

        viewModel.$appliedLiveRecognitionLocaleIdentifier
            .sink { [weak self] _ in
                guard let self else { return }
                liveRecognitionLocaleIdentifier = viewModel.liveRecognitionLocaleIdentifier
            }
            .store(in: &cancellables)

        viewModel.$activeTranscriptionMode
            .removeDuplicates()
            .sink { [weak self] in self?.activeTranscriptionMode = $0 }
            .store(in: &cancellables)

        viewModel.$availableMicrophones
            .removeDuplicates()
            .combineLatest(viewModel.$defaultInputDeviceID.removeDuplicates())
            .sink { [weak self] microphones, defaultDeviceID in
                guard let self else { return }
                availableMicrophones = microphones
                systemDefaultMicrophoneTitle = CaptionViewModel.systemDefaultMicrophoneTitle(
                    microphones: microphones,
                    defaultDeviceID: defaultDeviceID
                )
            }
            .store(in: &cancellables)

        viewModel.$filteredLocales
            .removeDuplicates()
            .sink { [weak self] in self?.filteredLocales = $0 }
            .store(in: &cancellables)

        viewModel.$availableWindows
            .removeDuplicates()
            .sink { [weak self] in self?.availableWindows = $0 }
            .store(in: &cancellables)

        viewModel.$screenshotCaptureSource
            .removeDuplicates()
            .sink { [weak self] in self?.screenshotCaptureSource = $0 }
            .store(in: &cancellables)

        viewModel.$canBeginRecording
            .removeDuplicates()
            .sink { [weak self] in self?.canBeginRecording = $0 }
            .store(in: &cancellables)
    }
}
