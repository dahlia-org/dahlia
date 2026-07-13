@preconcurrency import AVFoundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct MicrophoneCaptureDiagnosticsTests {
        @Test
        func recordsOrderedSnapshotsForCurrentCapture() throws {
            let diagnostics = MicrophoneCaptureDiagnostics(modeProvider: {
                (preferred: .voiceIsolation, active: .standard)
            })

            let captureID = diagnostics.beginCapture(context: .audioTest)
            diagnostics.record(
                captureID: captureID,
                stage: .voiceProcessingEnabled,
                voiceProcessingEnabled: true,
                voiceProcessingBypassed: false
            )

            let snapshots = diagnostics.snapshots()
            #expect(snapshots.map(\.stage) == [.captureRequested, .voiceProcessingEnabled])
            #expect(snapshots.allSatisfy { $0.captureID == captureID })
            #expect(snapshots.allSatisfy { $0.context == .audioTest })
            #expect(snapshots.allSatisfy { $0.preferredMicrophoneMode == .voiceIsolation })
            #expect(snapshots.allSatisfy { $0.activeMicrophoneMode == .standard })
            let enabledSnapshot = try #require(snapshots.last)
            #expect(enabledSnapshot.voiceProcessingEnabled == true)
            #expect(enabledSnapshot.voiceProcessingBypassed == false)
        }

        @Test
        func beginningNewCaptureReplacesPreviousLog() throws {
            let diagnostics = MicrophoneCaptureDiagnostics(modeProvider: {
                (preferred: .standard, active: .standard)
            })
            let previousCaptureID = diagnostics.beginCapture(context: .recording)
            diagnostics.record(captureID: previousCaptureID, stage: .engineStarted)

            let currentCaptureID = diagnostics.beginCapture(context: .audioTest)
            diagnostics.record(captureID: previousCaptureID, stage: .attemptFailed)

            let snapshots = diagnostics.snapshots()
            #expect(snapshots.count == 1)
            let snapshot = try #require(snapshots.first)
            #expect(snapshot.captureID == currentCaptureID)
            #expect(snapshot.context == .audioTest)
            #expect(snapshot.stage == .captureRequested)
        }
    }
#endif
