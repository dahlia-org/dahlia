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

        @Test
        func showsWaitingPlaceholderWhenSourceModeExcludesAvailableCaptions() throws {
            let previousEnabled = AppSettings.shared.liveSubtitleOverlayEnabled
            let previousSourceMode = AppSettings.shared.liveSubtitleSourceMode
            AppSettings.shared.liveSubtitleOverlayEnabled = true
            AppSettings.shared.liveSubtitleSourceMode = .systemAudioOnly
            defer {
                AppSettings.shared.liveSubtitleOverlayEnabled = previousEnabled
                AppSettings.shared.liveSubtitleSourceMode = previousSourceMode
            }

            let viewModel = CaptionViewModel(
                availableInputDevicesProvider: { [] },
                defaultInputDeviceIDProvider: { nil }
            )
            let sessionID = UUID.v7()
            viewModel.isListening = true
            viewModel.liveCaptionStore.start(sessionId: sessionID)
            // systemAudioOnly はマイク音声を除外するため、latest(...) は nil を返す。
            viewModel.liveCaptionStore.apply(event: .finalized(
                TranscriptSegment(
                    sessionId: sessionID,
                    startTime: .now,
                    text: "Microphone speech",
                    isConfirmed: true,
                    speakerLabel: "mic"
                )
            ))
            let presenter = FakeLiveSubtitlePresenter()

            let coordinator = LiveSubtitleOverlayCoordinator(
                viewModel: viewModel,
                liveSubtitleOverlayService: presenter
            )

            // オーバーレイは隠されず、待機プレースホルダーが表示される。
            let payload = try #require(presenter.lastPayload)
            #expect(payload.entries.count == 1)
            #expect(payload.entries.first?.secondaryText == nil)
            #expect(presenter.hideCount == 0)
            withExtendedLifetime(coordinator) {}
        }

        @Test
        func continuouslyChangingPreviewPublishesLatestAtBoundedCadence() async throws {
            let previousSetting = AppSettings.shared.liveSubtitleOverlayEnabled
            AppSettings.shared.liveSubtitleOverlayEnabled = true
            defer { AppSettings.shared.liveSubtitleOverlayEnabled = previousSetting }

            let viewModel = CaptionViewModel(
                availableInputDevicesProvider: { [] },
                defaultInputDeviceIDProvider: { nil }
            )
            let sessionID = UUID.v7()
            viewModel.isListening = true
            viewModel.liveCaptionStore.start(sessionId: sessionID)
            let presenter = FakeLiveSubtitlePresenter()
            let coordinator = LiveSubtitleOverlayCoordinator(
                viewModel: viewModel,
                liveSubtitleOverlayService: presenter
            )
            try await Task.sleep(for: .milliseconds(20))
            let initialUpdateCount = presenter.updateCount

            for index in 0 ..< 20 {
                viewModel.liveCaptionStore.apply(event: .preview(
                    TranscriptSegment(
                        sessionId: sessionID,
                        startTime: .now,
                        text: "Preview \(index)",
                        speakerLabel: "system"
                    )
                ))
            }

            try await Task.sleep(for: .milliseconds(500))

            let payload = try #require(presenter.lastPayload)
            #expect(payload.entries.map(\.primaryText) == ["Preview 19"])
            #expect(presenter.updateCount - initialUpdateCount <= 2)
            withExtendedLifetime(coordinator) {}
        }
    }
#endif
