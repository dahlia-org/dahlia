@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct MicrophoneRecognitionTestModelTests {
        @Test
        func defaultsToAutomaticScreenCaptureKitPath() {
            let model = MicrophoneRecognitionTestModel()

            #expect(model.startInfo == nil)
            #expect(model.showsRawInputLevel)
            #expect(!model.showsProcessedInputLevel)
            #expect(!model.showsReferenceInputLevel)
            #expect(model.capturePathDescription == L10n.screenCaptureAutomaticDescription)
        }

        @Test
        func monitorRefreshesCaptureDiagnosticsUntilCancelled() async {
            var providerCallCount = 0
            let initial = makeSnapshot(stage: .captureRequested)
            let refreshed = makeSnapshot(stage: .screenCaptureKitConfigured)
            let model = MicrophoneRecognitionTestModel(
                diagnosticsRefreshDelay: { throw CancellationError() },
                captureDiagnosticsProvider: {
                    providerCallCount += 1
                    return providerCallCount == 1 ? [initial] : [refreshed]
                }
            )

            await model.monitorDiagnostics()

            #expect(model.captureDiagnostics == [refreshed])
            #expect(providerCallCount == 2)
        }

        private func makeSnapshot(stage: MicrophoneCaptureDiagnosticStage) -> MicrophoneCaptureDiagnosticSnapshot {
            MicrophoneCaptureDiagnosticSnapshot(
                id: .v7(),
                captureID: .v7(),
                timestamp: .now,
                context: .audioTest,
                stage: stage,
                selectedDeviceID: nil,
                defaultDeviceID: nil,
                activeDeviceID: nil,
                activeDeviceName: nil,
                deviceRunningBeforeCapture: nil,
                inputHardwareFormat: nil,
                inputClientFormat: nil,
                targetFormat: nil,
                detail: nil
            )
        }
    }
#endif
