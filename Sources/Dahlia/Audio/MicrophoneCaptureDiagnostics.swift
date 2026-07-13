@preconcurrency import AVFoundation
import Foundation
import os

final class MicrophoneCaptureDiagnostics: Sendable {
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
    func beginCapture(context: MicrophoneCaptureContext) -> UUID {
        let captureID = UUID.v7()
        let modes = modeProvider()
        let snapshot = makeSnapshot(
            captureID: captureID,
            context: context,
            stage: .captureRequested,
            modes: modes
        )
        state.withLock { state in
            state.captureID = captureID
            state.context = context
            state.snapshots = [snapshot]
        }
        return captureID
    }

    func record(
        captureID: UUID,
        stage: MicrophoneCaptureDiagnosticStage,
        voiceProcessingEnabled: Bool? = nil,
        voiceProcessingBypassed: Bool? = nil,
        voiceProcessingInputMuted: Bool? = nil,
        voiceProcessingAGCEnabled: Bool? = nil,
        detail: String? = nil
    ) {
        let modes = modeProvider()
        state.withLock { state in
            guard state.captureID == captureID else { return }
            state.snapshots.append(makeSnapshot(
                captureID: captureID,
                context: state.context,
                stage: stage,
                modes: modes,
                voiceProcessingEnabled: voiceProcessingEnabled,
                voiceProcessingBypassed: voiceProcessingBypassed,
                voiceProcessingInputMuted: voiceProcessingInputMuted,
                voiceProcessingAGCEnabled: voiceProcessingAGCEnabled,
                detail: detail
            ))
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
            detail: detail
        )
    }
}
