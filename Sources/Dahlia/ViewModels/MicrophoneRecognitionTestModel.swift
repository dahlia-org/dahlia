import AppKit
import CoreAudio
import Foundation
import Observation

@MainActor
@Observable
final class MicrophoneRecognitionTestModel {
    private(set) var devices: [MicrophoneDevice] = []
    var selectedDeviceID: AudioDeviceID?
    private(set) var isRunning = false
    private(set) var isPreparing = false
    private(set) var inputLevel = 0.0
    private(set) var inputChannelLevels: [Double] = []
    private(set) var rawInputLevel = 0.0
    private(set) var processedInputLevel = 0.0
    private(set) var referenceInputLevel = 0.0
    private(set) var referenceBufferCount = 0
    private(set) var echoCancellationStatistics: WebRTCAEC3Statistics?
    private(set) var didBypassEchoCancellation = false
    private(set) var bufferCount = 0
    private(set) var recognizedText = ""
    private(set) var previewText = ""
    private(set) var errorMessage: String?
    private(set) var startInfo: AudioCaptureStartInfo?
    private(set) var captureDiagnostics: [MicrophoneCaptureDiagnosticSnapshot] = []

    private var session: MicrophoneRecognitionTestSession?
    private let diagnosticsRefreshDelay: () async throws -> Void
    private let captureDiagnosticsProvider: () -> [MicrophoneCaptureDiagnosticSnapshot]

    init(
        diagnosticsRefreshDelay: @escaping () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(250))
        },
        captureDiagnosticsProvider: @escaping () -> [MicrophoneCaptureDiagnosticSnapshot] = {
            MicrophoneCaptureDiagnostics.shared.snapshots()
        }
    ) {
        self.diagnosticsRefreshDelay = diagnosticsRefreshDelay
        self.captureDiagnosticsProvider = captureDiagnosticsProvider
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

    var capturePathDescription: String {
        if didBypassEchoCancellation {
            return L10n.screenCaptureRawFallbackDescription
        }
        return switch startInfo?.capturePath {
        case .screenCaptureRaw: L10n.screenCaptureRawDescription
        case .screenCaptureEchoCancellation: L10n.screenCaptureEchoCancellationDescription
        case nil: L10n.screenCaptureAutomaticDescription
        }
    }

    var showsRawInputLevel: Bool {
        true
    }

    var showsProcessedInputLevel: Bool {
        startInfo?.capturePath == .screenCaptureEchoCancellation
    }

    var showsReferenceInputLevel: Bool {
        startInfo?.capturePath == .screenCaptureEchoCancellation && !didBypassEchoCancellation
    }

    var processingLatencyText: String? {
        guard !didBypassEchoCancellation,
              let latency = startInfo?.processingLatency else { return nil }
        return Duration.seconds(latency).formatted(
            .units(allowed: [.milliseconds], width: .abbreviated, maximumUnitCount: 1)
        )
    }

    var diagnosticOutputDirectory: URL? {
        startInfo?.diagnosticOutputDirectory
    }

    var diagnosticAudioOutputDescription: String {
        startInfo?.capturePath == .screenCaptureRaw
            ? L10n.rawDiagnosticAudioOutputDescription
            : L10n.echoCancellationDiagnosticAudioOutputDescription
    }

    func refreshDevices() {
        devices = AudioCaptureManager.availableInputDevices()
        refreshCaptureDiagnostics()
    }

    func monitorDiagnostics() async {
        while !Task.isCancelled {
            refreshCaptureDiagnostics()
            do {
                try await diagnosticsRefreshDelay()
            } catch {
                return
            }
        }
    }

    func showDiagnosticOutputDirectory() {
        guard let diagnosticOutputDirectory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([diagnosticOutputDirectory])
    }

    func captureDiagnosticTitle(_ snapshot: MicrophoneCaptureDiagnosticSnapshot) -> String {
        "\(captureContextDisplayName(snapshot.context)) · \(L10n.microphoneCaptureStage(snapshot.stage))"
    }

    func captureDiagnosticTimestamp(_ snapshot: MicrophoneCaptureDiagnosticSnapshot) -> String {
        snapshot.timestamp.formatted(date: .omitted, time: .standard)
    }

    func captureDiagnosticDetails(_ snapshot: MicrophoneCaptureDiagnosticSnapshot) -> String {
        var components: [String] = []
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
        if let inputHardwareFormat = snapshot.inputHardwareFormat {
            components.append("hardware=\(inputHardwareFormat)")
        }
        if let inputClientFormat = snapshot.inputClientFormat {
            components.append("client=\(inputClientFormat)")
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
    }

    private func start() async {
        isPreparing = true
        inputLevel = 0
        inputChannelLevels = []
        rawInputLevel = 0
        processedInputLevel = 0
        referenceInputLevel = 0
        referenceBufferCount = 0
        echoCancellationStatistics = nil
        didBypassEchoCancellation = false
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
        case let .inputChannelLevels(levels):
            inputChannelLevels = levels
        case let .signalLevels(raw, processed):
            if let raw {
                rawInputLevel = raw
            }
            if let processed {
                processedInputLevel = processed
            }
        case let .referenceSignal(level, bufferCount):
            referenceInputLevel = level
            referenceBufferCount = bufferCount
        case let .echoCancellationStatistics(statistics):
            echoCancellationStatistics = statistics
        case .echoCancellationBypassed:
            didBypassEchoCancellation = true
            echoCancellationStatistics = nil
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
            if errorMessage == nil {
                errorMessage = L10n.microphoneCaptureStopped
            }
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
        rawInputLevel = 0
        processedInputLevel = 0
        referenceInputLevel = 0
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

}
