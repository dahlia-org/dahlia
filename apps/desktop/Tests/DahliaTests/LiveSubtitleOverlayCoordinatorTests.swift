import Foundation

#if canImport(Testing)
    import Testing
    @testable import Dahlia

    @MainActor
    @Suite(.serialized)
    struct LiveSubtitleOverlayCoordinatorTests {
        @Test
        func overlayReadsEphemeralCaptionStoreInsteadOfAuthoritativeTranscript() throws {
            let settingsSnapshot = UserDefaultsValueSnapshot(key: "liveSubtitleOverlayEnabled")
            AppSettings.shared.liveSubtitleOverlayEnabled = true
            defer { settingsSnapshot.restore() }

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
        func availableUpdateSlotConsumesStoreChangeSynchronously() {
            let settingsSnapshot = UserDefaultsValueSnapshot(key: "liveSubtitleOverlayEnabled")
            AppSettings.shared.liveSubtitleOverlayEnabled = true
            defer { settingsSnapshot.restore() }

            let viewModel = CaptionViewModel(
                availableInputDevicesProvider: { [] },
                defaultInputDeviceIDProvider: { nil }
            )
            let sessionID = UUID.v7()
            viewModel.isListening = true
            viewModel.liveCaptionStore.start(sessionId: sessionID)
            let presenter = FakeLiveSubtitlePresenter()
            let coordinator = LiveSubtitleOverlayCoordinator(viewModel: viewModel, liveSubtitleOverlayService: presenter)

            viewModel.liveCaptionStore.apply(event: .preview(TranscriptSegment(
                sessionId: sessionID,
                startTime: .now,
                text: "Immediate preview",
                speakerLabel: "system"
            )))

            #expect(presenter.lastPayload?.entries.map(\.primaryText) == ["Immediate preview"])
            withExtendedLifetime(coordinator) {}
        }

        @Test
        func clearImmediatelyFollowedByFinalizedDoesNotHideOverlay() async {
            let settingsSnapshot = UserDefaultsValueSnapshot(key: "liveSubtitleOverlayEnabled")
            AppSettings.shared.liveSubtitleOverlayEnabled = true
            defer { settingsSnapshot.restore() }

            let viewModel = CaptionViewModel(
                availableInputDevicesProvider: { [] },
                defaultInputDeviceIDProvider: { nil }
            )
            let sessionID = UUID.v7()
            let segmentID = UUID.v7()
            viewModel.isListening = true
            viewModel.liveCaptionStore.start(sessionId: sessionID)
            viewModel.liveCaptionStore.apply(event: .preview(TranscriptSegment(
                id: segmentID,
                sessionId: sessionID,
                startTime: .now,
                text: "Preview",
                speakerLabel: "system"
            )))
            let presenter = FakeLiveSubtitlePresenter()
            let coordinator = LiveSubtitleOverlayCoordinator(viewModel: viewModel, liveSubtitleOverlayService: presenter)
            let initialUpdateCount = presenter.updateCount

            viewModel.liveCaptionStore.apply(event: .clearPreview(sessionId: sessionID, sourceLabel: "system"))
            viewModel.liveCaptionStore.apply(event: .finalized(TranscriptSegment(
                id: segmentID,
                sessionId: sessionID,
                startTime: .now,
                text: "Final",
                isConfirmed: true,
                speakerLabel: "system"
            )))

            #expect(presenter.lastPayload?.entries.map(\.primaryText) == ["Preview"])
            #expect(presenter.updateCount == initialUpdateCount)
            let showedFinal = await waitUntil {
                presenter.lastPayload?.entries.map(\.primaryText) == ["Final"]
            }
            #expect(showedFinal)
            withExtendedLifetime(coordinator) {}
        }

        @Test
        func continuouslyChangingPreviewPublishesLatestAtBoundedCadence() async throws {
            let settingsSnapshot = UserDefaultsValueSnapshot(key: "liveSubtitleOverlayEnabled")
            AppSettings.shared.liveSubtitleOverlayEnabled = true
            defer { settingsSnapshot.restore() }

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
            let clock = ContinuousClock()
            let end = clock.now.advanced(by: .seconds(1))
            var index = 0

            while clock.now < end {
                viewModel.liveCaptionStore.apply(event: .preview(
                    TranscriptSegment(
                        sessionId: sessionID,
                        startTime: .now,
                        text: "Preview \(index)",
                        speakerLabel: "system"
                    )
                ))
                index += 1
                try await Task.sleep(for: .milliseconds(20))
            }

            let latestPreview = "Preview \(index - 1)"
            let showedLatestPreview = await waitUntil {
                presenter.lastPayload?.entries.map(\.primaryText) == [latestPreview]
            }
            #expect(showedLatestPreview)

            let payload = try #require(presenter.lastPayload)
            #expect(payload.entries.map(\.primaryText) == [latestPreview])
            let publishedPreviews = Set(presenter.payloadTextUpdates.compactMap(\.first).filter {
                $0.hasPrefix("Preview ")
            })
            #expect(publishedPreviews.count <= 7)
            withExtendedLifetime(coordinator) {}
        }

        @Test
        func microphoneSettingUpdatesVisibleCaptionsWhileRecording() async {
            let settingsSnapshots = [
                UserDefaultsValueSnapshot(key: "liveSubtitleOverlayEnabled"),
                UserDefaultsValueSnapshot(key: "liveSubtitleOverlaySegmentCount"),
                UserDefaultsValueSnapshot(key: "liveSubtitleSourceMode"),
            ]
            defer {
                for snapshot in settingsSnapshots {
                    snapshot.restore()
                }
            }

            let settings = AppSettings.shared
            settings.liveSubtitleOverlayEnabled = true
            settings.liveSubtitleOverlaySegmentCount = 2
            settings.liveSubtitleSourceMode = .includeMicrophone

            let viewModel = CaptionViewModel(
                availableInputDevicesProvider: { [] },
                defaultInputDeviceIDProvider: { nil }
            )
            let sessionID = UUID.v7()
            viewModel.isListening = true
            viewModel.liveCaptionStore.start(sessionId: sessionID)
            viewModel.liveCaptionStore.apply(event: .finalized(
                TranscriptSegment(
                    sessionId: sessionID,
                    startTime: .now,
                    text: "Microphone",
                    isConfirmed: true,
                    speakerLabel: "mic"
                )
            ))
            viewModel.liveCaptionStore.apply(event: .finalized(
                TranscriptSegment(
                    sessionId: sessionID,
                    startTime: .now,
                    text: "System",
                    isConfirmed: true,
                    speakerLabel: "system"
                )
            ))
            let presenter = FakeLiveSubtitlePresenter()
            let coordinator = LiveSubtitleOverlayCoordinator(
                viewModel: viewModel,
                liveSubtitleOverlayService: presenter
            )

            #expect(presenter.lastPayload?.entries.map(\.primaryText) == ["Microphone", "System"])

            settings.includesMicrophoneInLiveSubtitles = false
            let hidMicrophone = await waitUntil {
                presenter.lastPayload?.entries.map(\.primaryText) == ["System"]
            }
            #expect(hidMicrophone)

            settings.includesMicrophoneInLiveSubtitles = true
            let restoredMicrophone = await waitUntil {
                presenter.lastPayload?.entries.map(\.primaryText) == ["Microphone", "System"]
            }
            #expect(restoredMicrophone)
            withExtendedLifetime(coordinator) {}
        }

        private func waitUntil(_ predicate: @MainActor () -> Bool) async -> Bool {
            await pollUntil { predicate() }
        }
    }

    private struct UserDefaultsValueSnapshot {
        let key: String
        let value: Any?

        init(key: String) {
            self.key = key
            value = UserDefaults.standard.object(forKey: key)
        }

        func restore() {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
#endif
