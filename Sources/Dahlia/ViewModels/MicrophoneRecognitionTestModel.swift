import AVFoundation
import CoreAudio
import Foundation
import Observation

@MainActor
@Observable
final class MicrophoneRecognitionTestModel {
    private(set) var devices: [MicrophoneDevice] = []
    var selectedDeviceID: AudioDeviceID?
    private(set) var preferredMicrophoneMode = AVCaptureDevice.preferredMicrophoneMode
    private(set) var activeMicrophoneMode = AVCaptureDevice.activeMicrophoneMode
    private(set) var isRunning = false
    private(set) var isPreparing = false
    private(set) var inputLevel = 0.0
    private(set) var inputChannelLevels: [Double] = []
    private(set) var bufferCount = 0
    private(set) var recognizedText = ""
    private(set) var previewText = ""
    private(set) var errorMessage: String?
    private(set) var startInfo: AudioCaptureStartInfo?

    private var session: MicrophoneRecognitionTestSession?

    var isActive: Bool {
        isRunning || isPreparing
    }

    var statusText: String {
        if isPreparing {
            L10n.preparingAudioRecognitionTest
        } else if isRunning {
            L10n.audioRecognitionTestListening
        } else {
            L10n.audioRecognitionTestStopped
        }
    }

    var displayedTranscript: String {
        [recognizedText, previewText]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    var preferredMicrophoneModeText: String {
        Self.microphoneModeDisplayName(preferredMicrophoneMode)
    }

    var activeMicrophoneModeText: String {
        Self.microphoneModeDisplayName(activeMicrophoneMode)
    }

    func refreshDevices() {
        devices = AudioCaptureManager.availableInputDevices()
        refreshMicrophoneModes()
    }

    func refreshMicrophoneModes() {
        preferredMicrophoneMode = AVCaptureDevice.preferredMicrophoneMode
        activeMicrophoneMode = AVCaptureDevice.activeMicrophoneMode
    }

    func showMicrophoneModes() {
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
    }

    func toggle() async {
        if isActive {
            await stop()
        } else {
            await start()
        }
    }

    func stop() async {
        guard let session else {
            resetRunningState()
            return
        }
        self.session = nil
        resetRunningState()
        await session.stop()
        refreshMicrophoneModes()
    }

    private func start() async {
        isPreparing = true
        inputLevel = 0
        inputChannelLevels = []
        bufferCount = 0
        recognizedText = ""
        previewText = ""
        errorMessage = nil
        startInfo = nil

        let session = MicrophoneRecognitionTestSession()
        self.session = session
        do {
            let startInfo = try await session.start(
                deviceID: selectedDeviceID,
                locale: Locale(identifier: AppSettings.shared.transcriptionLocale)
            ) { [weak self] event in
                self?.handle(event)
            }
            guard self.session === session else {
                await session.stop()
                return
            }
            self.startInfo = startInfo
            isRunning = true
            isPreparing = false
            refreshMicrophoneModes()
        } catch {
            await session.stop()
            guard self.session === session else { return }
            self.session = nil
            errorMessage = error.localizedDescription
            resetRunningState()
        }
    }

    private func handle(_ event: MicrophoneRecognitionTestEvent) {
        switch event {
        case let .inputLevel(level, bufferCount):
            inputLevel = level
            self.bufferCount = bufferCount
            if bufferCount == 1 {
                refreshMicrophoneModes()
            }
        case let .inputChannelLevels(levels):
            inputChannelLevels = levels
        case let .transcript(text, isFinal):
            if isFinal {
                recognizedText = [recognizedText, text]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                previewText = ""
            } else {
                previewText = text
            }
        case let .failure(message):
            errorMessage = message
        case .captureStopped:
            errorMessage = L10n.microphoneCaptureStopped
            Task {
                await stop()
            }
        }
    }

    private func resetRunningState() {
        isPreparing = false
        isRunning = false
        inputLevel = 0
        inputChannelLevels = []
    }

    static func microphoneModeDisplayName(_ mode: AVCaptureDevice.MicrophoneMode) -> String {
        switch mode {
        case .standard: L10n.microphoneModeStandard
        case .wideSpectrum: L10n.microphoneModeWideSpectrum
        case .voiceIsolation: L10n.microphoneModeVoiceIsolation
        @unknown default: L10n.microphoneModeUnknown
        }
    }
}
