import Foundation

extension AudioCaptureManager {
    @objc func engineConfigurationDidChange() {
        lifecycleQueue.async { [weak self] in
            guard let self else { return }
            if let captureID = activeDiagnosticCaptureID {
                recordDiagnosticSnapshot(
                    captureID: captureID,
                    stage: .configurationChanged,
                    inputNode: engine.inputNode,
                    detail: "notificationReceived=true"
                )
            }
            lifecycleQueue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
                self?.recoverFromConfigurationChangeIfNeeded()
            }
        }
    }

    private func recoverFromConfigurationChangeIfNeeded() {
        let lifecycleDescription = String(describing: lifecycleState)
        let engineIsRunning = engine.isRunning
        let hasActiveRequest = activeRequest != nil
        guard lifecycleState == .running,
              !engineIsRunning,
              let request = activeRequest else {
            recordNonInterruptingConfigurationChange(
                lifecycleDescription: lifecycleDescription,
                hasActiveRequest: hasActiveRequest
            )
            return
        }
        lifecycleState = .restarting
        activeRequest = nil
        if let captureID = activeDiagnosticCaptureID {
            recordDiagnosticSnapshot(
                captureID: captureID,
                stage: .restartStarted,
                inputNode: engine.inputNode,
                detail: "lifecycle=\(lifecycleDescription) engineRunning=\(engineIsRunning)"
            )
            finishCaptureDiagnostics(stage: .captureStopped, detail: "reason=configurationChange")
        }
        restartCaptureAfterConfigurationChange(request)
    }

    private func recordNonInterruptingConfigurationChange(
        lifecycleDescription: String,
        hasActiveRequest: Bool
    ) {
        guard let captureID = activeDiagnosticCaptureID else { return }
        recordDiagnosticSnapshot(
            captureID: captureID,
            stage: .configurationChanged,
            inputNode: engine.inputNode,
            detail: "lifecycle=\(lifecycleDescription) activeRequest=\(hasActiveRequest) restartRequired=false"
        )
    }

    private func restartCaptureAfterConfigurationChange(_ request: CaptureRequest) {
        guard lifecycleState == .restarting else { return }
        resetCaptureAttempt()
        activeDiagnosticCaptureID = nil
        do {
            try startCaptureAfterConfigurationChange(request)
        } catch {
            captureRestartFailed(error)
        }
    }

    private func startCaptureAfterConfigurationChange(_ request: CaptureRequest) throws {
        _ = try startCapture(request)
        activeRequest = request
        lifecycleState = .running
        guard let captureID = activeDiagnosticCaptureID else { return }
        recordDiagnosticSnapshot(
            captureID: captureID,
            stage: .restartSucceeded,
            inputNode: engine.inputNode
        )
    }

    private func captureRestartFailed(_ error: any Error) {
        if let captureID = activeDiagnosticCaptureID {
            recordDiagnosticSnapshot(
                captureID: captureID,
                stage: .restartFailed,
                inputNode: engine.inputNode,
                detail: error.localizedDescription
            )
        }
        resetCaptureAttempt()
        activeDiagnosticCaptureID = nil
        lifecycleState = .stopped
        notifyUnexpectedStop(Self.audioCaptureError(from: error))
    }
}
