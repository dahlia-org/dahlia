#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    struct RecordingSessionControllerLocaleTests {
        @Test
        func batchTranscriptionAndLiveRecognitionLocalesReconfigureIndependently() async throws {
            let runtime = try await RecordingSessionControllerTests().makeRuntime(
                mode: .batch,
                liveSubtitlesEnabled: true
            )
            var snapshot = try #require(await runtime.controller.snapshot())
            #expect(snapshot.transcriptionLocaleIdentifier == "ja_JP")
            #expect(snapshot.liveRecognitionLocaleIdentifier == "ja_JP")

            await runtime.probe.clear()
            snapshot = try await runtime.controller.changeLiveRecognitionLocale(
                to: Locale(identifier: "fr_FR"),
                translateSegment: nil
            )
            #expect(snapshot.transcriptionLocaleIdentifier == "ja_JP")
            #expect(snapshot.liveRecognitionLocaleIdentifier == "fr_FR")
            var actions = await runtime.probe.actions
            #expect(actions.contains(.recognitionStart(.microphone)))
            var restartedCapture = actions.contains(where: \.isCaptureStartOrStop)
            #expect(!restartedCapture)

            await runtime.probe.clear()
            snapshot = try await runtime.controller.changeTranscriptionLocale(
                to: Locale(identifier: "de_DE"),
                translateSegment: nil
            )
            #expect(snapshot.transcriptionLocaleIdentifier == "de_DE")
            #expect(snapshot.liveRecognitionLocaleIdentifier == "fr_FR")
            actions = await runtime.probe.actions
            #expect(!actions.contains(.recognitionStart(.microphone)))
            #expect(!actions.contains(.recognitionCancel(.microphone)))
            restartedCapture = actions.contains(where: \.isCaptureStartOrStop)
            #expect(!restartedCapture)

            _ = try await runtime.controller.stop()
            await runtime.controller.completeStop()
        }

        @Test
        func realtimeTranscriptionLocaleKeepsOneRecognizerAndLiveLocaleInSync() async throws {
            let runtime = try await RecordingSessionControllerTests().makeRuntime(
                mode: .realtime,
                liveSubtitlesEnabled: true
            )
            let snapshot = try await runtime.controller.changeTranscriptionLocale(
                to: Locale(identifier: "en_US"),
                translateSegment: nil
            )

            #expect(snapshot.transcriptionLocaleIdentifier == "en_US")
            #expect(snapshot.liveRecognitionLocaleIdentifier == "en_US")
            #expect(await runtime.controller.resourceCounts().recognizers == 2)
            _ = try await runtime.controller.stop()
            await runtime.controller.completeStop()
        }

        @Test
        func failedChatOnlyLocaleChangePreservesOldRecognizers() async throws {
            let runtime = try await RecordingSessionControllerTests().makeRuntime(
                mode: .batch,
                liveSubtitlesEnabled: false,
                liveChatEnabled: true,
                recognitionFailureMode: .sessionPreparationAfterInitial
            )
            await runtime.probe.clear()

            await #expect(throws: RecordingSessionControllerError.self) {
                try await runtime.controller.changeLiveRecognitionLocale(
                    to: Locale(identifier: "en_US"),
                    translateSegment: nil
                )
            }

            let snapshot = try #require(await runtime.controller.snapshot())
            #expect(snapshot.liveRecognitionLocaleIdentifier == "ja_JP")
            #expect(await runtime.controller.resourceCounts().recognizers == 2)
            let actions = await runtime.probe.actions
            #expect(!actions.contains(.recognitionCancel(.microphone)))
            #expect(!actions.contains(.recognitionCancel(.system)))
            _ = try await runtime.controller.stop()
            await runtime.controller.completeStop()
        }
    }

    enum FakeRecognitionFailureMode: Equatable {
        case none
        case modelPreparation
        case sessionPreparation
        case sessionPreparationAfterInitial
        case start
        case eventDuringStart
    }
#endif
