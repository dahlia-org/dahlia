#if canImport(Testing)
    @preconcurrency import AVFoundation
    import Foundation
    import GRDB
    import os
    import Testing
    @testable import Dahlia

    struct RecordingSessionControllerTests {
        private struct PlanExpectation {
            let mode: TranscriptionMode
            let liveSubtitlesEnabled: Bool
            let recognizerCount: Int
            let recorderCount: Int
        }

        @Test
        func lifecycleKeepsFinalModeWhileLiveSubtitlesChange() async throws {
            let runtime = try await makeRuntime(mode: .batch, liveSubtitlesEnabled: false)
            let sessionID = try #require(await runtime.controller.snapshot()?.sessionId)

            let updated = try await runtime.controller.setLiveSubtitlesEnabled(
                true,
                translateSegment: nil
            )
            #expect(updated.sessionId == sessionID)
            #expect(updated.plan.finalMode == .batch)
            #expect(updated.plan.liveSubtitlesEnabled)

            let reconfigured = try await runtime.controller.changeLocale(
                to: Locale(identifier: "en_US"),
                translateSegment: nil
            )
            #expect(reconfigured.localeIdentifier == "en_US")

            _ = try await runtime.controller.stop()
            await runtime.controller.completeStop()
            #expect(await runtime.controller.snapshot() == nil)
        }

        @Test
        func overlappingSessionsAreRejectedAndAbortReturnsToIdle() async throws {
            let runtime = try await makeRuntime(mode: .realtime, liveSubtitlesEnabled: true)
            let plan = TranscriptionSessionPlan(
                finalMode: .realtime,
                liveSubtitlesEnabled: true,
                retainBatchAudio: false
            )

            await #expect(throws: RecordingSessionControllerError.self) {
                try await runtime.controller.prepare(
                    RecordingSessionController.PreparationRequest(
                        sessionId: .v7(),
                        startedAt: .now,
                        plan: plan,
                        locale: Locale(identifier: "ja_JP"),
                        sources: [.init(source: .microphone)]
                    ),
                    onEvent: { _ in },
                    onRuntimeFailure: { _, _, _ in }
                )
            }

            await runtime.controller.abort()
            #expect(await runtime.controller.snapshot() == nil)
        }

        @Test
        func fourPlansCreateExactlyOneCaptureAndAtMostOneRecognizerPerSource() async throws {
            let cases = [
                PlanExpectation(mode: .realtime, liveSubtitlesEnabled: false, recognizerCount: 2, recorderCount: 0),
                PlanExpectation(mode: .realtime, liveSubtitlesEnabled: true, recognizerCount: 2, recorderCount: 0),
                PlanExpectation(mode: .batch, liveSubtitlesEnabled: false, recognizerCount: 0, recorderCount: 2),
                PlanExpectation(mode: .batch, liveSubtitlesEnabled: true, recognizerCount: 2, recorderCount: 2),
            ]

            for testCase in cases {
                let runtime = try await makeRuntime(
                    mode: testCase.mode,
                    liveSubtitlesEnabled: testCase.liveSubtitlesEnabled,
                    forcesExternalMicrophoneEchoCancellation: true
                )
                let counts = await runtime.controller.resourceCounts()
                let actions = await runtime.probe.actions

                #expect(counts.captures == 2)
                #expect(counts.recognizers == testCase.recognizerCount)
                #expect(counts.batchRecorders == testCase.recorderCount)
                #expect(counts.batchSchedulers == (testCase.mode == .batch ? 1 : 0))
                #expect(actions.contains(.captureConfiguration(.microphone, forcesEchoCancellation: true)))

                _ = try await runtime.controller.stop()
                await runtime.controller.completeStop()
            }
        }

        @Test
        func liveToggleAttachesOnlyBatchRecognizerAndNeverDuplicatesRealtimeRecognizer() async throws {
            let batch = try await makeRuntime(mode: .batch, liveSubtitlesEnabled: false)
            var counts = await batch.controller.resourceCounts()
            #expect(counts.recognizers == 0)

            _ = try await batch.controller.setLiveSubtitlesEnabled(true, translateSegment: nil)
            counts = await batch.controller.resourceCounts()
            #expect(counts.recognizers == 2)

            _ = try await batch.controller.setLiveSubtitlesEnabled(false, translateSegment: nil)
            counts = await batch.controller.resourceCounts()
            #expect(counts.recognizers == 0)
            _ = try await batch.controller.stop()
            await batch.controller.completeStop()

            let realtime = try await makeRuntime(mode: .realtime, liveSubtitlesEnabled: false)
            #expect(await realtime.controller.resourceCounts().recognizers == 2)
            _ = try await realtime.controller.setLiveSubtitlesEnabled(true, translateSegment: nil)
            #expect(await realtime.controller.resourceCounts().recognizers == 2)
            _ = try await realtime.controller.stop()
            await realtime.controller.completeStop()
        }

        @Test
        func liveChatKeepsBatchRecognizerWhenSubtitlesAreDisabled() async throws {
            let runtime = try await makeRuntime(mode: .batch, liveSubtitlesEnabled: false)

            var snapshot = try await runtime.controller.setLiveChatEnabled(true, translateSegment: nil)
            #expect(snapshot.plan.liveChatEnabled)
            #expect(await runtime.controller.resourceCounts().recognizers == 2)

            snapshot = try await runtime.controller.setLiveSubtitlesEnabled(true, translateSegment: nil)
            snapshot = try await runtime.controller.setLiveSubtitlesEnabled(false, translateSegment: nil)
            #expect(snapshot.plan.liveChatEnabled)
            #expect(!snapshot.plan.liveSubtitlesEnabled)
            #expect(await runtime.controller.resourceCounts().recognizers == 2)

            snapshot = try await runtime.controller.setLiveChatEnabled(false, translateSegment: nil)
            #expect(!snapshot.plan.requiresLiveRecognition)
            #expect(await runtime.controller.resourceCounts().recognizers == 0)

            _ = try await runtime.controller.stop()
            await runtime.controller.completeStop()
        }

        @Test
        func failedBatchLiveToggleDoesNotCommitEnabledPlan() async throws {
            let runtime = try await makeRuntime(
                mode: .batch,
                liveSubtitlesEnabled: false,
                recognitionFailureMode: .modelPreparation
            )

            await #expect(throws: FakeRuntimeError.self) {
                try await runtime.controller.setLiveSubtitlesEnabled(true, translateSegment: nil)
            }

            let snapshot = try #require(await runtime.controller.snapshot())
            #expect(!snapshot.plan.liveSubtitlesEnabled)
            #expect(await runtime.controller.resourceCounts().recognizers == 0)
            _ = try await runtime.controller.stop()
            await runtime.controller.completeStop()
        }

        @Test
        func batchRecognitionFailureDoesNotWaitForItsOwnEventDelivery() async throws {
            let probe = RecordingRuntimeProbe()
            let control = SelfWaitingRecognitionControl()
            let failures = RuntimeFailureRecorder()
            let controller = RecordingSessionController(
                captureFactory: FakeAudioCaptureFactory(probe: probe),
                recognitionFactory: SelfWaitingRecognitionFactory(probe: probe, control: control),
                batchRecordingFactory: FakeBatchFactory(probe: probe)
            )
            let sessionID = UUID.v7()
            try await controller.prepare(
                RecordingSessionController.PreparationRequest(
                    sessionId: sessionID,
                    startedAt: .now,
                    plan: TranscriptionSessionPlan(
                        finalMode: .batch,
                        liveSubtitlesEnabled: true,
                        retainBatchAudio: false
                    ),
                    locale: Locale(identifier: "ja_JP"),
                    sources: [.init(source: .microphone)],
                    dbQueue: DatabaseQueue(),
                    meetingId: .v7(),
                    batchSampleRate: 16000
                ),
                onEvent: { _ in },
                onRuntimeFailure: { source, message, isFatal in
                    failures.append(source: source, message: message, isFatal: isFatal)
                }
            )
            _ = try await controller.startPrepared()

            await control.emitFailure()

            #expect(await controller.resourceCounts().recognizers == 0)
            let entries = await failures.entries
            #expect(entries.contains { $0.source == .microphone && !$0.isFatal })
            let result = try await controller.stop()
            #expect(result.batchRecordingSucceeded)
            await controller.completeStop()
        }

        @Test
        func retiredRecognitionCannotClearReplacementPreview() async throws {
            let probe = RecordingRuntimeProbe()
            let control = SelfWaitingRecognitionControl()
            let events = TranscriptionEventRecorder()
            let controller = RecordingSessionController(
                captureFactory: FakeAudioCaptureFactory(probe: probe),
                recognitionFactory: SelfWaitingRecognitionFactory(probe: probe, control: control),
                batchRecordingFactory: FakeBatchFactory(probe: probe)
            )
            let sessionID = UUID.v7()
            try await controller.prepare(
                RecordingSessionController.PreparationRequest(
                    sessionId: sessionID,
                    startedAt: .now,
                    plan: TranscriptionSessionPlan(
                        finalMode: .realtime,
                        liveSubtitlesEnabled: true,
                        retainBatchAudio: false
                    ),
                    locale: Locale(identifier: "ja_JP"),
                    sources: [.init(source: .microphone)]
                ),
                onEvent: { event in await events.append(event) },
                onRuntimeFailure: { _, _, _ in }
            )
            _ = try await controller.startPrepared()

            _ = try await controller.changeLocale(
                to: Locale(identifier: "en_US"),
                translateSegment: nil
            )

            let deliveredEvents = await events.events
            #expect(deliveredEvents.contains { event in
                guard case let .preview(segment) = event else { return false }
                return segment.text == "replacement preview"
            })
            #expect(!deliveredEvents.contains { event in
                if case .clearPreview = event { return true }
                return false
            })
            _ = try await controller.stop()
            await controller.completeStop()
        }

        @Test
        func stopOrdersCaptureBeforeRecognitionBeforeBatchAndWaitsForConfirmation() async throws {
            let runtime = try await makeRuntime(mode: .batch, liveSubtitlesEnabled: true)
            await runtime.probe.clear()

            let result = try await runtime.controller.stop()
            #expect(result.batchRecordingSucceeded)
            var actions = await runtime.probe.actions
            let lastCaptureStop = try #require(actions.lastIndex(where: { $0.isCaptureStop }))
            let firstRecognitionFinish = try #require(actions.firstIndex(where: { $0.isRecognitionFinish }))
            let batchFinish = try #require(actions.firstIndex(of: .batchFinish))
            #expect(lastCaptureStop < firstRecognitionFinish)
            #expect(firstRecognitionFinish < batchFinish)
            #expect(!actions.contains(.batchEnqueue))

            await runtime.controller.completeStop()
            actions = await runtime.probe.actions
            #expect(!actions.contains(.batchEnqueue))
        }

        @Test
        func localeChangeKeepsCaptureAndSourceChangeTouchesOnlyRequestedSource() async throws {
            let runtime = try await makeRuntime(mode: .realtime, liveSubtitlesEnabled: true)
            await runtime.probe.clear()

            let removed = try await runtime.controller.setSource(
                .init(source: .microphone),
                enabled: false,
                translateSegment: nil
            )
            #expect(removed.enabledSources == [.system])
            #expect(await runtime.controller.resourceCounts().captures == 1)
            #expect(await runtime.controller.resourceCounts().recognizers == 1)

            await runtime.probe.clear()
            _ = try await runtime.controller.changeLocale(
                to: Locale(identifier: "en_US"),
                translateSegment: nil
            )
            let localeActions = await runtime.probe.actions
            let restartedCapture = localeActions.contains(where: \.isCaptureStartOrStop)
            #expect(!restartedCapture)

            let restored = try await runtime.controller.setSource(
                .init(source: .microphone),
                enabled: true,
                translateSegment: nil
            )
            #expect(restored.enabledSources == [.microphone, .system])
            #expect(await runtime.controller.resourceCounts().captures == 2)
            _ = try await runtime.controller.stop()
            await runtime.controller.completeStop()
        }

        @Test
        func startFailureRollsBackAllPreparedResourcesAndBatchAudio() async throws {
            let probe = RecordingRuntimeProbe()
            let controller = RecordingSessionController(
                captureFactory: FakeAudioCaptureFactory(probe: probe, failingSource: .system),
                recognitionFactory: FakeRecognitionFactory(probe: probe),
                batchRecordingFactory: FakeBatchFactory(probe: probe)
            )
            try await controller.prepare(
                RecordingSessionController.PreparationRequest(
                    sessionId: .v7(),
                    startedAt: .now,
                    plan: TranscriptionSessionPlan(
                        finalMode: .batch,
                        liveSubtitlesEnabled: true,
                        retainBatchAudio: true
                    ),
                    locale: Locale(identifier: "ja_JP"),
                    sources: [.init(source: .microphone), .init(source: .system)],
                    dbQueue: DatabaseQueue(),
                    meetingId: .v7(),
                    batchSampleRate: 16000
                ),
                onEvent: { _ in },
                onRuntimeFailure: { _, _, _ in }
            )

            await #expect(throws: FakeRuntimeError.self) {
                try await controller.startPrepared()
            }
            #expect(await controller.snapshot() == nil)
            #expect(await controller.resourceCounts().captures == 0)
            #expect(await probe.actions.contains(.batchCancel))
        }

        @Test
        func batchLiveRecognitionFailuresKeepCaptureAndBatchRecordingRunning() async throws {
            let failureModes: [FakeRecognitionFailureMode] = [
                .modelPreparation,
                .sessionPreparation,
                .start,
                .eventDuringStart,
            ]

            for failureMode in failureModes {
                let failures = RuntimeFailureRecorder()
                let runtime = try await makeRuntime(
                    mode: .batch,
                    liveSubtitlesEnabled: true,
                    recognitionFailureMode: failureMode,
                    failureRecorder: failures
                )

                let counts = await runtime.controller.resourceCounts()
                #expect(counts.captures == 2)
                #expect(counts.recognizers == 0)
                #expect(counts.batchRecorders == 2)

                let warnings = await failures.entries
                #expect(!warnings.isEmpty)
                #expect(warnings.allSatisfy { !$0.isFatal })

                let actionsBeforeStop = await runtime.probe.actions
                #expect(!actionsBeforeStop.contains(.batchCancel))
                let result = try await runtime.controller.stop()
                #expect(result.batchRecordingSucceeded)
                await runtime.controller.completeStop()

                let finalActions = await runtime.probe.actions
                #expect(finalActions.contains(.batchFinish))
                #expect(!finalActions.contains(.batchEnqueue))
            }
        }

        @Test
        func recognitionFinishFailureIsFatalOnlyForRealtime() async throws {
            let realtimeFailures = RuntimeFailureRecorder()
            let realtime = try await makeRuntime(
                mode: .realtime,
                liveSubtitlesEnabled: true,
                failingRecognitionFinishSource: .microphone,
                failureRecorder: realtimeFailures
            )

            await #expect(throws: FakeRuntimeError.self) {
                try await realtime.controller.stop()
            }
            let realtimeEntries = await realtimeFailures.entries
            #expect(realtimeEntries.contains { $0.source == .microphone && $0.isFatal })
            await realtime.controller.completeStop()

            let batchFailures = RuntimeFailureRecorder()
            let batch = try await makeRuntime(
                mode: .batch,
                liveSubtitlesEnabled: true,
                failingRecognitionFinishSource: .microphone,
                failureRecorder: batchFailures
            )

            let batchResult = try await batch.controller.stop()
            #expect(batchResult.batchRecordingSucceeded)
            await batch.controller.completeStop()

            let batchEntries = await batchFailures.entries
            #expect(batchEntries.contains { $0.source == .microphone && !$0.isFatal })
            let batchActions = await batch.probe.actions
            #expect(batchActions.contains(.batchFinish))
            #expect(!batchActions.contains(.batchEnqueue))
        }

        @Test
        func sourceReplacementCaptureStartFailureRestoresPreviousRuntimeOnly() async throws {
            let replacementDeviceID = AudioDeviceID(42)
            let runtime = try await makeRuntime(
                mode: .realtime,
                liveSubtitlesEnabled: true,
                failingCaptureDeviceID: replacementDeviceID
            )
            await runtime.probe.clear()

            await #expect(throws: FakeRuntimeError.self) {
                try await runtime.controller.setSource(
                    .init(source: .microphone, captureDeviceID: replacementDeviceID),
                    enabled: true,
                    translateSegment: nil
                )
            }

            let snapshot = try #require(await runtime.controller.snapshot())
            let counts = await runtime.controller.resourceCounts()
            #expect(snapshot.enabledSources == [.microphone, .system])
            #expect(counts.captures == 2)
            #expect(counts.recognizers == 2)

            let replacementActions = await runtime.probe.actions
            let microphoneStarts = replacementActions.count(where: { $0 == .captureStart(.microphone) })
            #expect(microphoneStarts == 2)
            #expect(!replacementActions.contains(.captureStart(.system)))
            #expect(!replacementActions.contains(.captureStop(.system)))

            await runtime.probe.clear()
            _ = try await runtime.controller.setSource(
                .init(source: .microphone),
                enabled: true,
                translateSegment: nil
            )
            let unchangedActions = await runtime.probe.actions
            #expect(unchangedActions.isEmpty)

            _ = try await runtime.controller.stop()
            await runtime.controller.completeStop()
        }

        @Test
        func changingExternalMicrophoneEchoCancellationRebuildsOnlyMicrophoneCapture() async throws {
            let runtime = try await makeRuntime(mode: .realtime, liveSubtitlesEnabled: true)
            await runtime.probe.clear()

            _ = try await runtime.controller.setSource(
                .init(source: .microphone, forcesEchoCancellationForExternalMicrophone: true),
                enabled: true,
                translateSegment: nil
            )

            let actions = await runtime.probe.actions
            #expect(actions.contains(.captureConfiguration(.microphone, forcesEchoCancellation: true)))
            #expect(!actions.contains { action in
                if case .captureConfiguration(.system, _) = action { return true }
                return false
            })
            #expect(!actions.contains(.captureStart(.system)))
            #expect(!actions.contains(.captureStop(.system)))

            _ = try await runtime.controller.stop()
            await runtime.controller.completeStop()
        }

        @Test
        func sourceReplacementIgnoresWarningFromRetiredCapture() async throws {
            let warningStore = FakeCaptureWarningStore()
            let failures = RuntimeFailureRecorder()
            let runtime = try await makeRuntime(
                mode: .realtime,
                liveSubtitlesEnabled: true,
                failureRecorder: failures,
                warningStore: warningStore
            )
            let retiredWarning = try #require(warningStore.handlers(for: .microphone).first)

            _ = try await runtime.controller.setSource(
                .init(source: .microphone, forcesEchoCancellationForExternalMicrophone: true),
                enabled: true,
                translateSegment: nil
            )
            let currentWarning = try #require(warningStore.handlers(for: .microphone).last)

            retiredWarning(FakeWarning.retired)
            currentWarning(FakeWarning.current)
            await failures.waitUntilCount(1)
            let entries = await failures.entries

            #expect(entries == [
                .init(source: .microphone, message: "current warning", isFatal: false),
            ])

            _ = try await runtime.controller.stop()
            await runtime.controller.completeStop()
        }

        private func makeRuntime(
            mode: TranscriptionMode,
            liveSubtitlesEnabled: Bool,
            recognitionFailureMode: FakeRecognitionFailureMode = .none,
            failingRecognitionFinishSource: RecordingAudioSource? = nil,
            failingCaptureDeviceID: AudioDeviceID? = nil,
            forcesExternalMicrophoneEchoCancellation: Bool = false,
            failureRecorder: RuntimeFailureRecorder? = nil,
            warningStore: FakeCaptureWarningStore? = nil
        ) async throws -> (controller: RecordingSessionController, probe: RecordingRuntimeProbe) {
            let probe = RecordingRuntimeProbe()
            let scheduler = FakeBatchScheduler(probe: probe)
            let controller = RecordingSessionController(
                captureFactory: FakeAudioCaptureFactory(
                    probe: probe,
                    failingDeviceID: failingCaptureDeviceID,
                    warningStore: warningStore
                ),
                recognitionFactory: FakeRecognitionFactory(
                    probe: probe,
                    failureMode: recognitionFailureMode,
                    failingFinishSource: failingRecognitionFinishSource
                ),
                batchRecordingFactory: FakeBatchFactory(probe: probe)
            )
            let plan = TranscriptionSessionPlan(
                finalMode: mode,
                liveSubtitlesEnabled: liveSubtitlesEnabled,
                retainBatchAudio: mode == .batch
            )
            try await controller.prepare(
                RecordingSessionController.PreparationRequest(
                    sessionId: .v7(),
                    startedAt: .now,
                    plan: plan,
                    locale: Locale(identifier: "ja_JP"),
                    sources: [
                        .init(
                            source: .microphone,
                            forcesEchoCancellationForExternalMicrophone: forcesExternalMicrophoneEchoCancellation
                        ),
                        .init(source: .system),
                    ],
                    dbQueue: mode == .batch ? DatabaseQueue() : nil,
                    meetingId: mode == .batch ? .v7() : nil,
                    batchSampleRate: mode == .batch ? 16000 : nil,
                    batchScheduler: mode == .batch ? scheduler : nil
                ),
                onEvent: { _ in },
                onRuntimeFailure: { source, message, isFatal in
                    failureRecorder?.append(source: source, message: message, isFatal: isFatal)
                }
            )
            _ = try await controller.startPrepared()
            return (controller, probe)
        }
    }

    actor RecordingRuntimeProbe {
        enum Action: Equatable {
            case captureConfiguration(RecordingAudioSource, forcesEchoCancellation: Bool)
            case captureStart(RecordingAudioSource)
            case captureStop(RecordingAudioSource)
            case recognitionStart(RecordingAudioSource)
            case recognitionFinish(RecordingAudioSource)
            case recognitionCancel(RecordingAudioSource)
            case batchFinish
            case batchCancel
            case batchEnqueue

            var isCaptureStop: Bool {
                if case .captureStop = self { return true }
                return false
            }

            var isRecognitionFinish: Bool {
                if case .recognitionFinish = self { return true }
                return false
            }

            var isCaptureStartOrStop: Bool {
                switch self {
                case .captureStart, .captureStop:
                    true
                default:
                    false
                }
            }
        }

        private(set) var actions: [Action] = []

        func append(_ action: Action) {
            actions.append(action)
        }

        func clear() {
            actions.removeAll()
        }
    }

    @MainActor
    private final class RuntimeFailureRecorder {
        struct Entry: Equatable {
            let source: RecordingAudioSource?
            let message: String
            let isFatal: Bool
        }

        private(set) var entries: [Entry] = []
        private var countWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

        func append(source: RecordingAudioSource?, message: String, isFatal: Bool) {
            entries.append(Entry(source: source, message: message, isFatal: isFatal))
            let ready = countWaiters.filter { entries.count >= $0.count }
            countWaiters.removeAll { entries.count >= $0.count }
            ready.forEach { $0.continuation.resume() }
        }

        func waitUntilCount(_ count: Int) async {
            guard entries.count < count else { return }
            await withCheckedContinuation { continuation in
                countWaiters.append((count, continuation))
            }
        }
    }

    private enum FakeWarning: LocalizedError {
        case retired
        case current

        var errorDescription: String? {
            switch self {
            case .retired: "retired warning"
            case .current: "current warning"
            }
        }
    }

    private final class FakeCaptureWarningStore: @unchecked Sendable {
        private struct State {
            var handlers: [RecordingAudioSource: [AudioCaptureWarningHandler]] = [:]
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        func append(_ handler: @escaping AudioCaptureWarningHandler, for source: RecordingAudioSource) {
            state.withLock { $0.handlers[source, default: []].append(handler) }
        }

        func handlers(for source: RecordingAudioSource) -> [AudioCaptureWarningHandler] {
            state.withLock { $0.handlers[source] ?? [] }
        }
    }

    private actor TranscriptionEventRecorder {
        private(set) var events: [TranscriptionEvent] = []

        func append(_ event: TranscriptionEvent) {
            events.append(event)
        }
    }

    private struct FakeAudioCaptureFactory: AudioCaptureSessionFactory {
        let probe: RecordingRuntimeProbe
        let failingSource: RecordingAudioSource?
        let failingDeviceID: AudioDeviceID?
        let warningStore: FakeCaptureWarningStore?

        init(
            probe: RecordingRuntimeProbe,
            failingSource: RecordingAudioSource? = nil,
            failingDeviceID: AudioDeviceID? = nil,
            warningStore: FakeCaptureWarningStore? = nil
        ) {
            self.probe = probe
            self.failingSource = failingSource
            self.failingDeviceID = failingDeviceID
            self.warningStore = warningStore
        }

        func requestPermission(for _: RecordingAudioSource) async throws {}

        func makeSession(
            for pipeline: AudioSourcePipeline,
            onWarning: @escaping AudioCaptureWarningHandler,
            onUnexpectedStop _: @escaping AudioCaptureUnexpectedStopHandler
        ) -> any AudioCaptureSession {
            warningStore?.append(onWarning, for: pipeline.source)
            let deviceShouldFail = failingDeviceID.map { pipeline.captureDeviceID == $0 } ?? false
            return FakeAudioCaptureSession(
                source: pipeline.source,
                probe: probe,
                forcesEchoCancellation: pipeline.forcesEchoCancellationForExternalMicrophone,
                shouldFail: pipeline.source == failingSource || deviceShouldFail
            )
        }
    }

    private actor FakeAudioCaptureSession: AudioCaptureSession {
        let source: RecordingAudioSource
        let probe: RecordingRuntimeProbe
        let forcesEchoCancellation: Bool
        let shouldFail: Bool

        init(
            source: RecordingAudioSource,
            probe: RecordingRuntimeProbe,
            forcesEchoCancellation: Bool,
            shouldFail: Bool
        ) {
            self.source = source
            self.probe = probe
            self.forcesEchoCancellation = forcesEchoCancellation
            self.shouldFail = shouldFail
        }

        func start() async throws {
            await probe.append(.captureConfiguration(
                source,
                forcesEchoCancellation: forcesEchoCancellation
            ))
            await probe.append(.captureStart(source))
            if shouldFail {
                throw FakeRuntimeError.captureStart
            }
        }

        func stop() async throws {
            await probe.append(.captureStop(source))
        }
    }

    private struct FakeRecognitionFactory: ProgressiveRecognitionSessionFactory {
        let probe: RecordingRuntimeProbe
        let failureMode: FakeRecognitionFailureMode
        let failingFinishSource: RecordingAudioSource?

        init(
            probe: RecordingRuntimeProbe,
            failureMode: FakeRecognitionFailureMode = .none,
            failingFinishSource: RecordingAudioSource? = nil
        ) {
            self.probe = probe
            self.failureMode = failureMode
            self.failingFinishSource = failingFinishSource
        }

        func prepareModel(locale _: Locale) async throws {
            if failureMode == .modelPreparation {
                throw FakeRuntimeError.recognitionModelPreparation
            }
        }

        func prepareSession(
            locale _: Locale,
            source: RecordingAudioSource,
            sourceFormat _: AVAudioFormat?,
            bufferingMode _: AudioBufferBridge.BufferingMode,
            translateSegment _: ProgressiveSegmentTranslationHandler?
        ) async throws -> PreparedProgressiveRecognitionSession {
            if failureMode == .sessionPreparation {
                throw FakeRuntimeError.recognitionSessionPreparation
            }
            let format = try #require(AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16000,
                channels: 1,
                interleaved: false
            ))
            return PreparedProgressiveRecognitionSession(
                analyzerFormat: format,
                session: FakeRecognitionSession(
                    source: source,
                    probe: probe,
                    shouldFailStart: failureMode == .start,
                    shouldEmitFailureDuringStart: failureMode == .eventDuringStart,
                    shouldFailFinish: source == failingFinishSource
                )
            )
        }
    }

    private actor FakeRecognitionSession: ProgressiveRecognitionSession {
        nonisolated let pipelineID = UUID.v7()
        nonisolated let liveConsumer: AudioFrameRouter.LiveConsumer = { _ in true }

        private let source: RecordingAudioSource
        private let probe: RecordingRuntimeProbe
        private let shouldFailStart: Bool
        private let shouldEmitFailureDuringStart: Bool
        private let shouldFailFinish: Bool

        init(
            source: RecordingAudioSource,
            probe: RecordingRuntimeProbe,
            shouldFailStart: Bool,
            shouldEmitFailureDuringStart: Bool,
            shouldFailFinish: Bool
        ) {
            self.source = source
            self.probe = probe
            self.shouldFailStart = shouldFailStart
            self.shouldEmitFailureDuringStart = shouldEmitFailureDuringStart
            self.shouldFailFinish = shouldFailFinish
        }

        func start(
            recordingStartTime _: Date,
            recordingSessionId: UUID,
            onEvent: @escaping ProgressiveTranscriptionEventHandler
        ) async throws {
            await probe.append(.recognitionStart(source))
            if shouldFailStart {
                throw FakeRuntimeError.recognitionStart
            }
            if shouldEmitFailureDuringStart {
                await onEvent(.failure(
                    sessionId: recordingSessionId,
                    pipelineID: pipelineID,
                    sourceLabel: source.speakerLabel,
                    message: "recognition failed during start"
                ))
            }
        }

        func finish() async throws {
            await probe.append(.recognitionFinish(source))
            if shouldFailFinish {
                throw FakeRuntimeError.recognitionFinish
            }
        }

        func cancel() async {
            await probe.append(.recognitionCancel(source))
        }
    }

    private struct FakeBatchFactory: BatchRecordingSessionFactory {
        let probe: RecordingRuntimeProbe

        func makeSession(
            dbQueue _: DatabaseQueue,
            managedRootURL _: URL,
            meetingId _: UUID,
            recordingSessionId _: UUID,
            recordingStartTime _: Date,
            sampleRate _: Double
        ) throws -> any BatchRecordingSession {
            try FakeBatchSession(probe: probe)
        }
    }

    private final class FakeBatchSession: BatchRecordingSession {
        let targetFormat: AVAudioFormat
        private let probe: RecordingRuntimeProbe

        init(probe: RecordingRuntimeProbe) throws {
            self.probe = probe
            targetFormat = try #require(AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16000,
                channels: 1,
                interleaved: false
            ))
        }

        func beginRangeConsumer(
            source: RecordingAudioSource,
            locale _: Locale,
            at _: Date,
            continuingFromActiveRange _: Bool
        ) async throws -> BatchRecordingConsumerAttachment {
            BatchRecordingConsumerAttachment(
                consumer: { _ in },
                origin: BatchRecordingRangeOrigin(
                    source: source,
                    startFrame: 0,
                    sessionRelativeOriginSeconds: 0
                )
            )
        }

        func rotateRanges(
            _ origins: [BatchRecordingRangeOrigin],
            locale _: Locale
        ) async throws -> [RecordingAudioSource: BatchRecordingRangeOrigin] {
            Dictionary(uniqueKeysWithValues: origins.map { ($0.source, $0) })
        }

        func endRangeForReconfiguration(source _: RecordingAudioSource) async throws {}

        func finish() async throws {
            await probe.append(.batchFinish)
        }

        func cancelPreservingAudio() async {
            await probe.append(.batchCancel)
        }
    }

    private actor FakeBatchScheduler: BatchTranscriptionScheduling {
        let probe: RecordingRuntimeProbe

        init(probe: RecordingRuntimeProbe) {
            self.probe = probe
        }

        func recoverAndEnqueue() async {}

        func enqueue(sessionId _: UUID) async {
            await probe.append(.batchEnqueue)
        }

        func isRunning(sessionId _: UUID) async -> Bool { false }
        func recordRecordingFailure(sessionId _: UUID, message _: String) async {}
    }

    private enum FakeRecognitionFailureMode: Equatable {
        case none
        case modelPreparation
        case sessionPreparation
        case start
        case eventDuringStart
    }

    private enum FakeRuntimeError: Error {
        case captureStart
        case recognitionModelPreparation
        case recognitionSessionPreparation
        case recognitionStart
        case recognitionFinish
    }
#endif
