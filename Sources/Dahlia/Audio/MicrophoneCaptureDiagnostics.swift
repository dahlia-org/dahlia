@preconcurrency import AVFoundation
import Foundation
import os

final class MicrophoneCaptureDiagnostics: Sendable {
    private static let logger = Logger(subsystem: "com.dahlia", category: "MicrophoneCapture")
    private static let maximumSnapshotCount = 200

    typealias MicrophoneModeProvider = @Sendable () -> (
        preferred: AVCaptureDevice.MicrophoneMode,
        active: AVCaptureDevice.MicrophoneMode
    )

    static let shared = MicrophoneCaptureDiagnostics()

    private struct State {
        var captureID: UUID?
        var context = MicrophoneCaptureContext.recording
        var snapshots: [MicrophoneCaptureDiagnosticSnapshot] = []
    }

    private let modeProvider: MicrophoneModeProvider
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(modeProvider: @escaping MicrophoneModeProvider = {
        (AVCaptureDevice.preferredMicrophoneMode, AVCaptureDevice.activeMicrophoneMode)
    }) {
        self.modeProvider = modeProvider
    }

    @discardableResult
    func beginCapture(
        context: MicrophoneCaptureContext,
        requestedVoiceProcessing: Bool? = nil,
        selectedDeviceID: AudioDeviceID? = nil,
        defaultDeviceID: AudioDeviceID? = nil,
        activeDeviceID: AudioDeviceID? = nil,
        activeDeviceName: String? = nil,
        deviceRunningBeforeCapture: Bool? = nil,
        targetFormat: String? = nil,
        detail: String? = nil
    ) -> UUID {
        let captureID = UUID.v7()
        let modes = modeProvider()
        let snapshot = makeSnapshot(
            captureID: captureID,
            context: context,
            stage: .captureRequested,
            modes: modes,
            requestedVoiceProcessing: requestedVoiceProcessing,
            selectedDeviceID: selectedDeviceID,
            defaultDeviceID: defaultDeviceID,
            activeDeviceID: activeDeviceID,
            activeDeviceName: activeDeviceName,
            deviceRunningBeforeCapture: deviceRunningBeforeCapture,
            targetFormat: targetFormat,
            detail: detail
        )
        state.withLock { state in
            state.captureID = captureID
            state.context = context
            state.snapshots = [snapshot]
        }
        Self.log(snapshot)
        return captureID
    }

    func record(
        captureID: UUID,
        stage: MicrophoneCaptureDiagnosticStage,
        voiceProcessingEnabled: Bool? = nil,
        voiceProcessingBypassed: Bool? = nil,
        voiceProcessingInputMuted: Bool? = nil,
        voiceProcessingAGCEnabled: Bool? = nil,
        requestedVoiceProcessing: Bool? = nil,
        selectedDeviceID: AudioDeviceID? = nil,
        defaultDeviceID: AudioDeviceID? = nil,
        activeDeviceID: AudioDeviceID? = nil,
        activeDeviceName: String? = nil,
        deviceRunningBeforeCapture: Bool? = nil,
        engineRunning: Bool? = nil,
        inputHardwareFormat: String? = nil,
        inputClientFormat: String? = nil,
        outputHardwareFormat: String? = nil,
        targetFormat: String? = nil,
        detail: String? = nil
    ) {
        let modes = modeProvider()
        let snapshot = state.withLock { state -> MicrophoneCaptureDiagnosticSnapshot? in
            guard state.captureID == captureID else { return nil }
            let snapshot = makeSnapshot(
                captureID: captureID,
                context: state.context,
                stage: stage,
                modes: modes,
                voiceProcessingEnabled: voiceProcessingEnabled,
                voiceProcessingBypassed: voiceProcessingBypassed,
                voiceProcessingInputMuted: voiceProcessingInputMuted,
                voiceProcessingAGCEnabled: voiceProcessingAGCEnabled,
                requestedVoiceProcessing: requestedVoiceProcessing,
                selectedDeviceID: selectedDeviceID,
                defaultDeviceID: defaultDeviceID,
                activeDeviceID: activeDeviceID,
                activeDeviceName: activeDeviceName,
                deviceRunningBeforeCapture: deviceRunningBeforeCapture,
                engineRunning: engineRunning,
                inputHardwareFormat: inputHardwareFormat,
                inputClientFormat: inputClientFormat,
                outputHardwareFormat: outputHardwareFormat,
                targetFormat: targetFormat,
                detail: detail
            )
            state.snapshots.append(snapshot)
            if state.snapshots.count > Self.maximumSnapshotCount {
                state.snapshots.removeFirst(state.snapshots.count - Self.maximumSnapshotCount)
            }
            return snapshot
        }
        if let snapshot {
            Self.log(snapshot)
        }
    }

    func snapshots() -> [MicrophoneCaptureDiagnosticSnapshot] {
        state.withLock { $0.snapshots }
    }

    private func makeSnapshot(
        captureID: UUID,
        context: MicrophoneCaptureContext,
        stage: MicrophoneCaptureDiagnosticStage,
        modes: (
            preferred: AVCaptureDevice.MicrophoneMode,
            active: AVCaptureDevice.MicrophoneMode
        ),
        voiceProcessingEnabled: Bool? = nil,
        voiceProcessingBypassed: Bool? = nil,
        voiceProcessingInputMuted: Bool? = nil,
        voiceProcessingAGCEnabled: Bool? = nil,
        requestedVoiceProcessing: Bool? = nil,
        selectedDeviceID: AudioDeviceID? = nil,
        defaultDeviceID: AudioDeviceID? = nil,
        activeDeviceID: AudioDeviceID? = nil,
        activeDeviceName: String? = nil,
        deviceRunningBeforeCapture: Bool? = nil,
        engineRunning: Bool? = nil,
        inputHardwareFormat: String? = nil,
        inputClientFormat: String? = nil,
        outputHardwareFormat: String? = nil,
        targetFormat: String? = nil,
        detail: String? = nil
    ) -> MicrophoneCaptureDiagnosticSnapshot {
        MicrophoneCaptureDiagnosticSnapshot(
            id: .v7(),
            captureID: captureID,
            timestamp: .now,
            context: context,
            stage: stage,
            preferredMicrophoneMode: modes.preferred,
            activeMicrophoneMode: modes.active,
            voiceProcessingEnabled: voiceProcessingEnabled,
            voiceProcessingBypassed: voiceProcessingBypassed,
            voiceProcessingInputMuted: voiceProcessingInputMuted,
            voiceProcessingAGCEnabled: voiceProcessingAGCEnabled,
            requestedVoiceProcessing: requestedVoiceProcessing,
            selectedDeviceID: selectedDeviceID,
            defaultDeviceID: defaultDeviceID,
            activeDeviceID: activeDeviceID,
            activeDeviceName: activeDeviceName,
            deviceRunningBeforeCapture: deviceRunningBeforeCapture,
            engineRunning: engineRunning,
            inputHardwareFormat: inputHardwareFormat,
            inputClientFormat: inputClientFormat,
            outputHardwareFormat: outputHardwareFormat,
            targetFormat: targetFormat,
            detail: detail
        )
    }

    nonisolated static func renderedLine(_ snapshot: MicrophoneCaptureDiagnosticSnapshot) -> String {
        var components = [
            "captureID=\(snapshot.captureID.uuidString)",
            "context=\(contextName(snapshot.context))",
            "stage=\(String(reflecting: snapshot.stage.rawValue))",
            "preferredMode=\(microphoneModeName(snapshot.preferredMicrophoneMode))",
            "activeMode=\(microphoneModeName(snapshot.activeMicrophoneMode))",
        ]
        append("requestedVP", snapshot.requestedVoiceProcessing, to: &components)
        append("vpEnabled", snapshot.voiceProcessingEnabled, to: &components)
        append("vpBypassed", snapshot.voiceProcessingBypassed, to: &components)
        append("vpMuted", snapshot.voiceProcessingInputMuted, to: &components)
        append("vpAGC", snapshot.voiceProcessingAGCEnabled, to: &components)
        append("selectedDevice", snapshot.selectedDeviceID, to: &components)
        append("defaultDevice", snapshot.defaultDeviceID, to: &components)
        append("activeDevice", snapshot.activeDeviceID, to: &components)
        appendQuoted("activeDeviceName", snapshot.activeDeviceName, to: &components)
        append("runningBeforeCapture", snapshot.deviceRunningBeforeCapture, to: &components)
        append("engineRunning", snapshot.engineRunning, to: &components)
        appendQuoted("inputHardwareFormat", snapshot.inputHardwareFormat, to: &components)
        appendQuoted("inputClientFormat", snapshot.inputClientFormat, to: &components)
        appendQuoted("outputHardwareFormat", snapshot.outputHardwareFormat, to: &components)
        appendQuoted("targetFormat", snapshot.targetFormat, to: &components)
        appendQuoted("detail", snapshot.detail, to: &components)
        return components.joined(separator: " ")
    }

    private static func log(_ snapshot: MicrophoneCaptureDiagnosticSnapshot) {
        let line = renderedLine(snapshot)
        switch snapshot.stage {
        case .attemptFailed, .restartFailed, .unexpectedStop:
            logger.error("\(line, privacy: .public)")
        default:
            logger.notice("\(line, privacy: .public)")
        }
    }

    private nonisolated static func append(
        _ key: String,
        _ value: (some CustomStringConvertible)?,
        to components: inout [String]
    ) {
        guard let value else { return }
        components.append("\(key)=\(value)")
    }

    private nonisolated static func appendQuoted(_ key: String, _ value: String?, to components: inout [String]) {
        guard let value else { return }
        components.append("\(key)=\(String(reflecting: value))")
    }

    private nonisolated static func contextName(_ context: MicrophoneCaptureContext) -> String {
        switch context {
        case .recording: "recording"
        case .audioTest: "audioTest"
        }
    }

    private nonisolated static func microphoneModeName(_ mode: AVCaptureDevice.MicrophoneMode) -> String {
        switch mode {
        case .standard: "standard"
        case .wideSpectrum: "wideSpectrum"
        case .voiceIsolation: "voiceIsolation"
        @unknown default: "unknown(\(mode.rawValue))"
        }
    }
}
