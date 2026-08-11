import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct UsageTelemetryServiceTests {
        @Test
        func startsOnceWithTrimmedPlistAppIDAndRequestedTestMode() async {
            let client = FakeUsageTelemetryClient()
            let service = UsageTelemetryService(client: client)

            service.start(
                infoDictionary: ["TELEMETRYDECK_APP_ID": "  test-app-id \n"],
                testMode: true
            )
            service.start(
                infoDictionary: ["TELEMETRYDECK_APP_ID": "another-id"],
                testMode: false
            )
            #expect(await waitUntilEnabled(service))

            #expect(client.starts == [.init(appID: "test-app-id", testMode: true)])
            #expect(service.isEnabled)
        }

        @Test
        func missingAppIDLeavesTelemetryDisabledAndDropsSignals() {
            let client = FakeUsageTelemetryClient()
            let service = UsageTelemetryService(client: client)

            service.start(infoDictionary: ["TELEMETRYDECK_APP_ID": " \n"], testMode: false)
            service.record(.summary(.started, trigger: .manual))

            #expect(client.starts.isEmpty)
            #expect(client.signals.isEmpty)
            #expect(!service.isEnabled)
        }

        @Test
        func recordsOnlyTheTypedEventContractAfterStartup() async {
            let client = FakeUsageTelemetryClient()
            let service = UsageTelemetryService(client: client)
            service.start(infoDictionary: ["TELEMETRYDECK_APP_ID": "app-id"], testMode: false)
            service.record(.summary(.started, trigger: .manual))
            #expect(client.signals.isEmpty)
            #expect(await waitUntilEnabled(service))

            service.record(.recording(
                .failed(.persistence),
                mode: .batch,
                sources: .microphoneAndSystemAudio,
                meetingScope: .continued,
                duration: nil
            ))
            service.record(.export(
                .completed,
                destination: .googleDocs,
                trigger: .summaryGeneration
            ))

            #expect(client.signals == [
                .init(
                    name: "Dahlia.Recording.failed",
                    parameters: [
                        "audioSources": "microphoneAndSystemAudio",
                        "meetingScope": "continued",
                        "stage": "persistence",
                        "transcriptionMode": "batch",
                    ],
                    floatValue: nil
                ),
                .init(
                    name: "Dahlia.Export.completed",
                    parameters: [
                        "destination": "googleDocs",
                        "trigger": "summaryGeneration",
                    ],
                    floatValue: nil
                ),
            ])
        }

        @Test
        func fixedEventValuesMatchTheDocumentedAllowlist() {
            #expect(UsageTelemetryEvent.TranscriptionModeValue.allCases.map(\.rawValue) == ["realtime", "batch"])
            #expect(UsageTelemetryEvent.AudioSources.allCases.map(\.rawValue) == [
                "microphone",
                "systemAudio",
                "microphoneAndSystemAudio",
            ])
            #expect(UsageTelemetryEvent.RecordingFailureStage.allCases.map(\.rawValue) == [
                "start",
                "capture",
                "stop",
                "persistence",
            ])
            #expect(UsageTelemetryEvent.MeetingScope.allCases.map(\.rawValue) == ["new", "continued"])
            #expect(UsageTelemetryEvent.TranscriptionFailureStage.allCases.map(\.rawValue) == [
                "start",
                "persistence",
                "transcription",
            ])
            #expect(UsageTelemetryEvent.SummaryFailureStage.allCases.map(\.rawValue) == ["generation"])
            #expect(UsageTelemetryEvent.ExportFailureStage.allCases.map(\.rawValue) == ["export"])
            #expect(UsageTelemetryEvent.SummaryTrigger.allCases.map(\.rawValue) == ["manual", "automaticAfterBatch"])
            #expect(UsageTelemetryEvent.ExportTrigger.allCases.map(\.rawValue) == ["manual", "summaryGeneration"])
            #expect(UsageTelemetryEvent.ExportDestination.allCases.map(\.rawValue) == ["vault", "googleDocs", "localFiles"])
        }

        @Test
        func lifecycleEncodesAStageOnlyForWorkflowSpecificFailures() {
            let recording = UsageTelemetryEvent.recording(
                .failed(.capture),
                mode: .realtime,
                sources: .microphone,
                meetingScope: .new,
                duration: nil
            )
            let transcription = UsageTelemetryEvent.transcription(.failed(.persistence), mode: .realtime)
            let summary = UsageTelemetryEvent.summary(.failed(.generation), trigger: .automaticAfterBatch)
            let export = UsageTelemetryEvent.export(.failed(.export), destination: .vault, trigger: .summaryGeneration)

            #expect(recording.signalName == "Dahlia.Recording.failed")
            #expect(recording.parameters["stage"] == "capture")
            #expect(transcription.signalName == "Dahlia.Transcription.failed")
            #expect(transcription.parameters["stage"] == "persistence")
            #expect(summary.signalName == "Dahlia.Summary.failed")
            #expect(summary.parameters["stage"] == "generation")
            #expect(export.signalName == "Dahlia.Export.failed")
            #expect(export.parameters["stage"] == "export")
            #expect(UsageTelemetryEvent.summary(.completed, trigger: .manual).parameters["stage"] == nil)
            #expect(UsageTelemetryEvent.export(
                .started,
                destination: .localFiles,
                trigger: .manual
            ).parameters["stage"] == nil)
        }

        @Test
        func recordingTerminalEventsKeepStartDimensionsAfterRuntimeFailure() {
            var context = RecordingTelemetryContext(
                mode: .realtime,
                audioSources: .microphoneAndSystemAudio,
                meetingScope: .continued
            )
            context.recordingFailureStage = .capture
            context.transcriptionFailureStage = .transcription

            #expect(context.terminalEvents(recordingDuration: 900) == [
                .recording(
                    .failed(.capture),
                    mode: .realtime,
                    sources: .microphoneAndSystemAudio,
                    meetingScope: .continued,
                    duration: nil
                ),
                .transcription(.failed(.transcription), mode: .realtime),
            ])
        }

        @Test
        func completedRecordingRoundsDurationToMinutesAndCapsAtSixHours() {
            func event(duration: TimeInterval) -> UsageTelemetryEvent {
                .recording(
                    .completed,
                    mode: .realtime,
                    sources: .microphone,
                    meetingScope: .new,
                    duration: duration
                )
            }

            #expect(event(duration: 29).floatValue == 0)
            #expect(event(duration: 30).floatValue == 1)
            #expect(event(duration: 90).floatValue == 2)
            #expect(event(duration: 21_600).floatValue == 360)
            #expect(event(duration: 86_400).floatValue == 360)
            #expect(UsageTelemetryEvent.recording(
                .failed(.stop),
                mode: .batch,
                sources: .systemAudio,
                meetingScope: .continued,
                duration: 600
            ).floatValue == nil)
        }

        private func waitUntilEnabled(_ service: UsageTelemetryService) async -> Bool {
            for _ in 0 ..< 10000 {
                if service.isEnabled { return true }
                await Task.yield()
            }
            return service.isEnabled
        }

        @Test
        func batchProgressEmitsOneStartAndOneTerminalEvent() async {
            var events: [UsageTelemetryEvent] = []
            let viewModel = CaptionViewModel(usageTelemetryReporter: { events.append($0) })
            let meetingID = UUID()
            let sessionID = UUID()

            await viewModel.handleBatchTranscriptionUpdate(.init(
                meetingId: meetingID,
                state: .queued(sessionId: sessionID)
            ))
            await viewModel.handleBatchTranscriptionUpdate(.init(
                meetingId: meetingID,
                state: .running(sessionId: sessionID)
            ))
            await viewModel.handleBatchTranscriptionUpdate(.init(
                meetingId: meetingID,
                state: .completed(sessionId: sessionID)
            ))
            await viewModel.handleBatchTranscriptionUpdate(.init(
                meetingId: meetingID,
                state: .completed(sessionId: sessionID)
            ))

            #expect(events == [
                .transcription(.started, mode: .batch),
                .transcription(.completed, mode: .batch),
            ])
        }

        @Test
        func batchRetryEmitsOneLifecyclePerAttempt() async {
            var events: [UsageTelemetryEvent] = []
            let viewModel = CaptionViewModel(usageTelemetryReporter: { events.append($0) })
            let meetingID = UUID()
            let sessionID = UUID()

            await viewModel.handleBatchTranscriptionUpdate(.init(
                meetingId: meetingID,
                state: .queued(sessionId: sessionID)
            ))
            await viewModel.handleBatchTranscriptionUpdate(.init(
                meetingId: meetingID,
                state: .failed(sessionId: sessionID, message: "first attempt")
            ))
            await viewModel.handleBatchTranscriptionUpdate(.init(
                meetingId: meetingID,
                state: .queued(sessionId: sessionID)
            ))
            await viewModel.handleBatchTranscriptionUpdate(.init(
                meetingId: meetingID,
                state: .completed(sessionId: sessionID)
            ))

            #expect(events == [
                .transcription(.started, mode: .batch),
                .transcription(.failed(.transcription), mode: .batch),
                .transcription(.started, mode: .batch),
                .transcription(.completed, mode: .batch),
            ])
        }
    }

    @MainActor
    private final class FakeUsageTelemetryClient: UsageTelemetryClient {
        struct Start: Equatable {
            let appID: String
            let testMode: Bool
        }

        struct Signal: Equatable {
            let name: String
            let parameters: [String: String]
            let floatValue: Double?
        }

        private(set) var starts: [Start] = []
        private(set) var signals: [Signal] = []

        func start(appID: String, testMode: Bool) async {
            starts.append(.init(appID: appID, testMode: testMode))
        }

        func signal(_ name: String, parameters: [String: String], floatValue: Double?) {
            signals.append(.init(name: name, parameters: parameters, floatValue: floatValue))
        }
    }
#endif
