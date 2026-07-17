import AVFoundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct MicrophoneRecognitionTestModelTests {
        @Test
        func monitorRefreshesMicrophoneModesUntilCancelled() async {
            var reportedModes = (
                preferred: AVCaptureDevice.MicrophoneMode.standard,
                active: AVCaptureDevice.MicrophoneMode.standard
            )
            var refreshDelayCount = 0
            let model = MicrophoneRecognitionTestModel(
                microphoneModeProvider: { reportedModes },
                microphoneModeRefreshDelay: {
                    refreshDelayCount += 1
                    guard refreshDelayCount == 1 else { throw CancellationError() }
                    reportedModes = (preferred: .voiceIsolation, active: .voiceIsolation)
                }
            )

            await model.monitorMicrophoneModes()

            #expect(model.preferredMicrophoneMode == .voiceIsolation)
            #expect(model.activeMicrophoneMode == .voiceIsolation)
            #expect(refreshDelayCount == 2)
        }
    }
#endif
