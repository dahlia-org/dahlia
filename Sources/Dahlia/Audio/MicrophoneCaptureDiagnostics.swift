import CoreAudio
import Foundation
import os

final class MicrophoneCaptureDiagnostics: Sendable {
    private static let logger = Logger(subsystem: "com.dahlia", category: "MicrophoneCapture")
    private static let maximumSnapshotCount = 200

    static let shared = MicrophoneCaptureDiagnostics()

    private struct State {
        var captureID: UUID?
        var context = MicrophoneCaptureContext.recording
        var snapshots: [MicrophoneCaptureDiagnosticSnapshot] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    @discardableResult
    func beginCapture(
        context: MicrophoneCaptureContext,
        selectedDeviceID: AudioDeviceID? = nil,
        defaultDeviceID: AudioDeviceID? = nil,
        activeDeviceID: AudioDeviceID? = nil,
        activeDeviceName: String? = nil,
        deviceRunningBeforeCapture: Bool? = nil,
        targetFormat: String? = nil,
        detail: String? = nil
    ) -> UUID {
        let captureID = UUID.v7()
        let snapshot = makeSnapshot(
            captureID: captureID,
            context: context,
            stage: .captureRequested,
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
        selectedDeviceID: AudioDeviceID? = nil,
        defaultDeviceID: AudioDeviceID? = nil,
        activeDeviceID: AudioDeviceID? = nil,
        activeDeviceName: String? = nil,
        deviceRunningBeforeCapture: Bool? = nil,
        inputHardwareFormat: String? = nil,
        inputClientFormat: String? = nil,
        targetFormat: String? = nil,
        detail: String? = nil
    ) {
        let snapshot = state.withLock { state -> MicrophoneCaptureDiagnosticSnapshot? in
            guard state.captureID == captureID else { return nil }
            let snapshot = makeSnapshot(
                captureID: captureID,
                context: state.context,
                stage: stage,
                selectedDeviceID: selectedDeviceID,
                defaultDeviceID: defaultDeviceID,
                activeDeviceID: activeDeviceID,
                activeDeviceName: activeDeviceName,
                deviceRunningBeforeCapture: deviceRunningBeforeCapture,
                inputHardwareFormat: inputHardwareFormat,
                inputClientFormat: inputClientFormat,
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
        selectedDeviceID: AudioDeviceID? = nil,
        defaultDeviceID: AudioDeviceID? = nil,
        activeDeviceID: AudioDeviceID? = nil,
        activeDeviceName: String? = nil,
        deviceRunningBeforeCapture: Bool? = nil,
        inputHardwareFormat: String? = nil,
        inputClientFormat: String? = nil,
        targetFormat: String? = nil,
        detail: String? = nil
    ) -> MicrophoneCaptureDiagnosticSnapshot {
        MicrophoneCaptureDiagnosticSnapshot(
            id: .v7(),
            captureID: captureID,
            timestamp: .now,
            context: context,
            stage: stage,
            selectedDeviceID: selectedDeviceID,
            defaultDeviceID: defaultDeviceID,
            activeDeviceID: activeDeviceID,
            activeDeviceName: activeDeviceName,
            deviceRunningBeforeCapture: deviceRunningBeforeCapture,
            inputHardwareFormat: inputHardwareFormat,
            inputClientFormat: inputClientFormat,
            targetFormat: targetFormat,
            detail: detail
        )
    }

    nonisolated static func renderedLine(_ snapshot: MicrophoneCaptureDiagnosticSnapshot) -> String {
        var components = [
            "captureID=\(snapshot.captureID.uuidString)",
            "context=\(contextName(snapshot.context))",
            "stage=\(String(reflecting: snapshot.stage.rawValue))",
        ]
        append("selectedDevice", snapshot.selectedDeviceID, to: &components)
        append("defaultDevice", snapshot.defaultDeviceID, to: &components)
        append("activeDevice", snapshot.activeDeviceID, to: &components)
        appendQuoted("activeDeviceName", snapshot.activeDeviceName, to: &components)
        append("runningBeforeCapture", snapshot.deviceRunningBeforeCapture, to: &components)
        appendQuoted("inputHardwareFormat", snapshot.inputHardwareFormat, to: &components)
        appendQuoted("inputClientFormat", snapshot.inputClientFormat, to: &components)
        appendQuoted("targetFormat", snapshot.targetFormat, to: &components)
        appendQuoted("detail", snapshot.detail, to: &components)
        return components.joined(separator: " ")
    }

    private static func log(_ snapshot: MicrophoneCaptureDiagnosticSnapshot) {
        let line = renderedLine(snapshot)
        switch snapshot.stage {
        case .attemptFailed, .unexpectedStop:
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
}
