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

        @Test
        func rendersStructuredCaptureMetadata() throws {
            let diagnostics = MicrophoneCaptureDiagnostics(modeProvider: {
                (preferred: .voiceIsolation, active: .standard)
            })
            let captureID = diagnostics.beginCapture(
                context: .recording,
                requestedVoiceProcessing: true,
                selectedDeviceID: 42,
                defaultDeviceID: 7,
                activeDeviceID: 42,
                activeDeviceName: "USB Mic",
                deviceRunningBeforeCapture: true,
                targetFormat: "16000 Hz, 1 ch, Float32"
            )
            let snapshot = try #require(diagnostics.snapshots().first)

            let line = MicrophoneCaptureDiagnostics.renderedLine(snapshot)

            #expect(line.contains("captureID=\(captureID.uuidString)"))
            #expect(line.contains("context=recording"))
            #expect(line.contains("requestedVP=true"))
            #expect(line.contains("selectedDevice=42"))
            #expect(line.contains("runningBeforeCapture=true"))
            #expect(line.contains("activeDeviceName=\"USB Mic\""))
            #expect(line.contains("targetFormat=\"16000 Hz, 1 ch, Float32\""))
        }

        @Test
        func boundsInMemorySnapshots() {
            let diagnostics = MicrophoneCaptureDiagnostics(modeProvider: {
                (preferred: .standard, active: .standard)
            })
            let captureID = diagnostics.beginCapture(context: .recording)

            for index in 0 ..< 250 {
                diagnostics.record(captureID: captureID, stage: .captureHealth, detail: "index=\(index)")
            }

            let snapshots = diagnostics.snapshots()
            #expect(snapshots.count == 200)
            #expect(snapshots.last?.detail == "index=249")
        }
    }
#endif
