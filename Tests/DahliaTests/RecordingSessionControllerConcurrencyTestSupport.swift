#if canImport(Testing)
    @preconcurrency import AVFoundation
    import Foundation
    import Testing
    @testable import Dahlia

    struct SelfWaitingRecognitionFactory: ProgressiveRecognitionSessionFactory {
        let probe: RecordingRuntimeProbe
        let control: SelfWaitingRecognitionControl

        func prepareModel(locale _: Locale) async throws {}

        func prepareSession(
            locale _: Locale,
            source: RecordingAudioSource,
            sourceFormat _: AVAudioFormat?,
            bufferingMode _: AudioBufferBridge.BufferingMode,
            translateSegment _: ProgressiveSegmentTranslationHandler?
        ) async throws -> PreparedProgressiveRecognitionSession {
            let format = try #require(AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16000,
                channels: 1,
                interleaved: false
            ))
            return PreparedProgressiveRecognitionSession(
                analyzerFormat: format,
                session: SelfWaitingRecognitionSession(source: source, probe: probe, control: control)
            )
        }
    }

    private actor SelfWaitingRecognitionSession: ProgressiveRecognitionSession {
        nonisolated let pipelineID = UUID.v7()
        nonisolated let liveConsumer: AudioFrameRouter.LiveConsumer = { _ in true }

        private let source: RecordingAudioSource
        private let probe: RecordingRuntimeProbe
        private let control: SelfWaitingRecognitionControl

        init(source: RecordingAudioSource, probe: RecordingRuntimeProbe, control: SelfWaitingRecognitionControl) {
            self.source = source
            self.probe = probe
            self.control = control
        }

        func start(
            recordingStartTime _: Date,
            recordingSessionId: UUID,
            onEvent: @escaping ProgressiveTranscriptionEventHandler
        ) async throws {
            await probe.append(.recognitionStart(source))
            await control.register(
                sessionID: recordingSessionId,
                pipelineID: pipelineID,
                source: source,
                handler: onEvent
            )
        }

        func finish() async throws {
            await control.finish(pipelineID: pipelineID)
            await probe.append(.recognitionFinish(source))
        }

        func cancel() async {
            await control.waitForActiveDelivery()
            await probe.append(.recognitionCancel(source))
        }
    }

    actor SelfWaitingRecognitionControl {
        private struct Registration {
            let sessionID: UUID
            let pipelineID: UUID
            let source: RecordingAudioSource
            let handler: ProgressiveTranscriptionEventHandler
        }

        private var registrations: [Registration] = []
        private var activeDelivery: Task<Void, Never>?

        func register(
            sessionID: UUID,
            pipelineID: UUID,
            source: RecordingAudioSource,
            handler: @escaping ProgressiveTranscriptionEventHandler
        ) {
            registrations.append(Registration(
                sessionID: sessionID,
                pipelineID: pipelineID,
                source: source,
                handler: handler
            ))
        }

        func emitFailure() async {
            guard let registration = registrations.last else { return }
            let delivery = Task {
                await registration.handler(.failure(
                    sessionId: registration.sessionID,
                    pipelineID: registration.pipelineID,
                    sourceLabel: registration.source.speakerLabel,
                    message: "runtime recognition failure"
                ))
            }
            activeDelivery = delivery
            await delivery.value
            activeDelivery = nil
        }

        func waitForActiveDelivery() async {
            await activeDelivery?.value
        }

        func finish(pipelineID: UUID) async {
            guard let retiring = registrations.first(where: { $0.pipelineID == pipelineID }),
                  let latest = registrations.last,
                  latest.pipelineID != retiring.pipelineID else { return }
            let preview = TranscriptSegment(
                sessionId: latest.sessionID,
                startTime: .now,
                text: "replacement preview",
                isConfirmed: false,
                speakerLabel: latest.source.speakerLabel
            )
            await latest.handler(.preview(preview))
            await retiring.handler(.clearPreview(
                sessionId: retiring.sessionID,
                sourceLabel: retiring.source.speakerLabel
            ))
        }
    }
#endif
