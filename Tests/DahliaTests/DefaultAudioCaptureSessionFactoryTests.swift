@testable import Dahlia

#if canImport(Testing)
    import os
    import Testing

    struct DefaultAudioCaptureSessionFactoryTests {
        @Test
        func microphonePermissionRequiresMicrophoneAndScreenRecording() async throws {
            let requests = OSAllocatedUnfairLock(initialState: [String]())
            let factory = DefaultAudioCaptureSessionFactory(
                requestMicrophonePermission: {
                    requests.withLock { $0.append("microphone") }
                    return true
                },
                requestScreenRecordingPermission: {
                    requests.withLock { $0.append("screenRecording") }
                    return true
                }
            )

            try await factory.requestPermission(for: .microphone)

            #expect(requests.withLock { $0 } == ["microphone", "screenRecording"])
        }

        @Test
        func microphoneDenialDoesNotRequestScreenRecording() async {
            let screenRequestCount = OSAllocatedUnfairLock(initialState: 0)
            let factory = DefaultAudioCaptureSessionFactory(
                requestMicrophonePermission: { false },
                requestScreenRecordingPermission: {
                    screenRequestCount.withLock { $0 += 1 }
                    return true
                }
            )

            await #expect(throws: AudioCaptureError.self) {
                try await factory.requestPermission(for: .microphone)
            }
            #expect(screenRequestCount.withLock { $0 } == 0)
        }

        @Test
        func microphoneCaptureReportsScreenRecordingDenialPrecisely() async {
            let factory = DefaultAudioCaptureSessionFactory(
                requestMicrophonePermission: { true },
                requestScreenRecordingPermission: { false }
            )

            await #expect(throws: SystemAudioCaptureError.self) {
                try await factory.requestPermission(for: .microphone)
            }
        }
    }
#endif
