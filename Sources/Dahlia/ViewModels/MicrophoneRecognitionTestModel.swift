import AVFoundation
import CoreAudio
import Foundation
import Observation

@MainActor
@Observable
final class MicrophoneRecognitionTestModel {
    private(set) var devices: [MicrophoneDevice] = []
    var selectedDeviceID: AudioDeviceID?
    private(set) var preferredMicrophoneMode: AVCaptureDevice.MicrophoneMode
    private(set) var activeMicrophoneMode: AVCaptureDevice.MicrophoneMode
    private(set) var isRunning = false
    private(set) var isPreparing = false
    private(set) var inputLevel = 0.0
    private(set) var inputChannelLevels: [Double] = []
    private(set) var bufferCount = 0
    private(set) var recognizedText = ""
    private(set) var previewText = ""
    private(set) var errorMessage: String?
    private(set) var startInfo: AudioCaptureStartInfo?
    private(set) var captureDiagnostics: [MicrophoneCaptureDiagnosticSnapshot] = []

    private var session: MicrophoneRecognitionTestSession?
    private let microphoneModeProvider: () -> (
        preferred: AVCaptureDevice.MicrophoneMode,
        active: AVCaptureDevice.MicrophoneMode
    )
    private let microphoneModeRefreshDelay: () async throws -> Void
    private let captureDiagnosticsProvider: () -> [MicrophoneCaptureDiagnosticSnapshot]

    init(
        microphoneModeProvider: @escaping () -> (
            preferred: AVCaptureDevice.MicrophoneMode,
            active: AVCaptureDevice.MicrophoneMode
        ) = {
            (AVCaptureDevice.preferredMicrophoneMode, AVCaptureDevice.activeMicrophoneMode)
        },
        microphoneModeRefreshDelay: @escaping () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(250))
        },
        captureDiagnosticsProvider: @escaping () -> [MicrophoneCaptureDiagnosticSnapshot] = {
            MicrophoneCaptureDiagnostics.shared.snapshots()
        }
    ) {
        self.microphoneModeProvider = microphoneModeProvider
        self.microphoneModeRefreshDelay = microphoneModeRefreshDelay
        self.captureDiagnosticsProvider = captureDiagnosticsProvider
        let microphoneModes = microphoneModeProvider()
        preferredMicrophoneMode = microphoneModes.preferred
        activeMicrophoneMode = microphoneModes.active
        captureDiagnostics = captureDiagnosticsProvider()
    }

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
        refreshCaptureDiagnostics()
    }

    func refreshMicrophoneModes() {
        let microphoneModes = microphoneModeProvider()
        preferredMicrophoneMode = microphoneModes.preferred
        activeMicrophoneMode = microphoneModes.active
    }

    func monitorMicrophoneModes() async {
        while !Task.isCancelled {
            refreshMicrophoneModes()
            refreshCaptureDiagnostics()
            do {
                try await microphoneModeRefreshDelay()
            } catch {
                return
            }
        }
    }

    func showMicrophoneModes() {
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
    }

    func captureDiagnosticTitle(_ snapshot: MicrophoneCaptureDiagnosticSnapshot) -> String {
        "\(captureContextDisplayName(snapshot.context)) · \(L10n.microphoneCaptureStage(snapshot.stage))"
    }

    func captureDiagnosticTimestamp(_ snapshot: MicrophoneCaptureDiagnosticSnapshot) -> String {
        snapshot.timestamp.formatted(date: .omitted, time: .standard)
    }

    func captureDiagnosticDetails(_ snapshot: MicrophoneCaptureDiagnosticSnapshot) -> String {
        var components = [
            "\(L10n.preferredMicrophoneMode)=\(Self.microphoneModeDisplayName(snapshot.preferredMicrophoneMode))",
            "\(L10n.activeMicrophoneMode)=\(Self.microphoneModeDisplayName(snapshot.activeMicrophoneMode))",
        ]
        if let enabled = snapshot.voiceProcessingEnabled {
            components.append("VP=\(enabled)")
        }
        if let bypassed = snapshot.voiceProcessingBypassed {
            components.append("bypass=\(bypassed)")
        }
        if let muted = snapshot.voiceProcessingInputMuted {
            components.append("mute=\(muted)")
        }
        if let agcEnabled = snapshot.voiceProcessingAGCEnabled {
            components.append("AGC=\(agcEnabled)")
        }
        if let requestedVoiceProcessing = snapshot.requestedVoiceProcessing {
            components.append("requestedVP=\(requestedVoiceProcessing)")
        }
        if let selectedDeviceID = snapshot.selectedDeviceID {
            components.append("selectedDevice=\(selectedDeviceID)")
        }
        if let defaultDeviceID = snapshot.defaultDeviceID {
            components.append("defaultDevice=\(defaultDeviceID)")
        }
        if let activeDeviceID = snapshot.activeDeviceID {
            components.append("activeDevice=\(activeDeviceID)")
        }
        if let activeDeviceName = snapshot.activeDeviceName {
            components.append(activeDeviceName)
        }
        if let deviceRunningBeforeCapture = snapshot.deviceRunningBeforeCapture {
            components.append("runningBeforeCapture=\(deviceRunningBeforeCapture)")
        }
        if let engineRunning = snapshot.engineRunning {
            components.append("engineRunning=\(engineRunning)")
        }
        if let inputHardwareFormat = snapshot.inputHardwareFormat {
            components.append("hardware=\(inputHardwareFormat)")
        }
        if let inputClientFormat = snapshot.inputClientFormat {
            components.append("client=\(inputClientFormat)")
        }
        if let outputHardwareFormat = snapshot.outputHardwareFormat {
            components.append("output=\(outputHardwareFormat)")
        }
        if let targetFormat = snapshot.targetFormat {
            components.append("target=\(targetFormat)")
        }
        if let detail = snapshot.detail {
            components.append(detail)
        }
        return components.joined(separator: " · ")
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
            refreshCaptureDiagnostics()
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

    private func refreshCaptureDiagnostics() {
        captureDiagnostics = captureDiagnosticsProvider()
    }

    private func captureContextDisplayName(_ context: MicrophoneCaptureContext) -> String {
        switch context {
        case .recording: L10n.microphoneCaptureRecording
        case .audioTest: L10n.microphoneCaptureAudioTest
        }
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
