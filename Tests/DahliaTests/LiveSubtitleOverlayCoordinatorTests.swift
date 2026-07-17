import Foundation

#if canImport(Testing)
    import Testing
    @testable import Dahlia

    @MainActor
    @Suite(.serialized)
    struct LiveSubtitleOverlayCoordinatorTests {
        @Test
        func overlayReadsEphemeralCaptionStoreInsteadOfAuthoritativeTranscript() throws {
            let previousSetting = AppSettings.shared.liveSubtitleOverlayEnabled
            AppSettings.shared.liveSubtitleOverlayEnabled = true
            defer { AppSettings.shared.liveSubtitleOverlayEnabled = previousSetting }

            let viewModel = CaptionViewModel(
                availableInputDevicesProvider: { [] },
                defaultInputDeviceIDProvider: { nil }
            )
            let sessionID = UUID.v7()
            viewModel.isListening = true
            viewModel.store.addSegment(
                TranscriptSegment(
                    sessionId: sessionID,
                    startTime: .now,
                    text: "Historical transcript",
                    isConfirmed: true,
                    speakerLabel: "system"
                )
            )
            viewModel.liveCaptionStore.start(sessionId: sessionID)
            viewModel.liveCaptionStore.apply(event: .finalized(
                TranscriptSegment(
                    sessionId: sessionID,
                    startTime: .now,
                    text: "Ephemeral live caption",
                    isConfirmed: true,
                    speakerLabel: "system"
                )
            ))
            let presenter = FakeLiveSubtitlePresenter()

            _ = LiveSubtitleOverlayCoordinator(
                viewModel: viewModel,
                liveSubtitleOverlayService: presenter
            )

            let payload = try #require(presenter.lastPayload)
            #expect(payload.entries.map(\.primaryText) == ["Ephemeral live caption"])
        }
    }
#endif
