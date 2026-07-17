@preconcurrency import AVFoundation
import CoreMedia
import Foundation

extension RecordingSessionController {
    func startPreparedSource(
        _ preparedSource: PreparedSource,
        locale: Locale,
        snapshot: Snapshot
    ) async throws {
        let configuration = preparedSource.configuration
        let runtimeID = try beginSourceRuntimeGeneration(
            source: configuration.source,
            sessionId: snapshot.sessionId
        )
        let captureFormat = try await preparedCaptureFormat(for: preparedSource)
        let captureOriginDate = Date.now
        let pipeline = AudioSourcePipeline(
            source: configuration.source,
            captureFormat: captureFormat,
            captureDeviceID: configuration.captureDeviceID,
            captureBufferSize: configuration.captureBufferSize,
            sessionRelativeOrigin: CMTime(
                seconds: max(0, captureOriginDate.timeIntervalSince(snapshot.startedAt)),
                preferredTimescale: 1_000_000
            )
        )
        let batchRangeOrigin = try await attachInitialBatchRange(
            to: pipeline,
            source: configuration.source,
            locale: locale,
            captureOriginDate: captureOriginDate
        )
        let recognition = try await startPreparedRecognition(
            preparedSource.recognition?.session,
            source: configuration.source,
            pipeline: pipeline,
            snapshot: snapshot
        )

        try requireCurrentSourceRuntimeGeneration(
            source: configuration.source,
            runtimeID: runtimeID,
            sessionId: snapshot.sessionId
        )
        let capture = captureFactory.makeSession(
            for: pipeline,
            onUnexpectedStop: captureFailureHandler(
                source: configuration.source,
                runtimeID: runtimeID,
                sessionId: snapshot.sessionId
            )
        )
        sourceRuntimes[configuration.source] = SourceRuntime(
            id: runtimeID,
            pipeline: pipeline,
            capture: capture,
            recognition: recognition,
            batchRangeOrigin: batchRangeOrigin
        )
        try await capture.start()
        try requireCurrentSourceRuntime(
            source: configuration.source,
            runtimeID: runtimeID,
            sessionId: snapshot.sessionId
        )
    }

    private func attachInitialBatchRange(
        to pipeline: AudioSourcePipeline,
        source: RecordingAudioSource,
        locale: Locale,
        captureOriginDate: Date
    ) async throws -> BatchRecordingRangeOrigin? {
        guard let batchRecording else { return nil }
        let attachment = try await batchRecording.beginRangeConsumer(
            source: source,
            locale: locale,
            at: captureOriginDate,
            continuingFromActiveRange: false
        )
        pipeline.setSessionRelativeOrigin(seconds: attachment.origin.sessionRelativeOriginSeconds)
        pipeline.router.setBatchConsumer(attachment.consumer)
        return attachment.origin
    }

    private func preparedCaptureFormat(for source: PreparedSource) async throws -> AVAudioFormat {
        if let batchRecording {
            return batchRecording.targetFormat
        }
        guard let recognition = source.recognition else {
            throw AudioCaptureError.converterCreationFailed
        }
        return recognition.analyzerFormat
    }

    private func startPreparedRecognition(
        _ recognition: (any ProgressiveRecognitionSession)?,
        source: RecordingAudioSource,
        pipeline: AudioSourcePipeline,
        snapshot: Snapshot
    ) async throws -> (any ProgressiveRecognitionSession)? {
        guard let recognition else { return nil }
        do {
            try await startRecognition(recognition, source: source, snapshot: snapshot)
            try consumePendingRecognitionStart(
                pipelineID: recognition.pipelineID,
                source: source,
                sessionId: snapshot.sessionId
            )
            pipeline.router.setLiveConsumer(
                recognition.liveConsumer,
                bufferingMode: snapshot.plan.recordsBatchAudio
                    ? .lowLatency(maximumFrameCount: 8)
                    : .lossless,
                onFailure: liveFailureHandler(
                    source: source,
                    pipelineID: recognition.pipelineID,
                    sessionId: snapshot.sessionId
                )
            )
            return recognition
        } catch {
            guard snapshot.plan.finalMode == .batch else { throw error }
            await recognition.cancel()
            await onRuntimeFailure?(source, error.localizedDescription, false)
            return nil
        }
    }

}
