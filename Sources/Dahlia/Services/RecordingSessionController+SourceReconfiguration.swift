@preconcurrency import AVFoundation
import CoreMedia
import Foundation

extension RecordingSessionController {
    private struct SourcePipelinePreparation {
        let source: RecordingAudioSource
        let pipeline: AudioSourcePipeline
        let preparedRecognition: PreparedProgressiveRecognitionSession?
    }

    private struct RecognitionAttachment {
        let preparedRecognition: PreparedProgressiveRecognitionSession?
        let recognition: (any ProgressiveRecognitionSession)?
    }

    /// 対象音源だけを追加・削除する。他音源のcaptureは継続する。
    func setSource(
        _ configuration: SourceConfiguration,
        enabled: Bool,
        translateSegment: ProgressiveSegmentTranslationHandler?
    ) async throws -> Snapshot {
        guard case let .capturing(snapshot) = state,
              let locale = currentLocale else {
            throw RecordingSessionControllerError.sessionNotActive
        }
        let source = configuration.source
        if enabled, let runtime = sourceRuntimes[source] {
            let matchesConfiguration = runtime.pipeline.captureDeviceID == configuration.captureDeviceID
                && runtime.pipeline.captureBufferSize == configuration.captureBufferSize
            if matchesConfiguration { return snapshot }
            return try await replaceSource(
                runtime,
                with: configuration,
                locale: locale,
                snapshot: snapshot,
                translateSegment: translateSegment
            )
        } else if enabled {
            return try await addSource(
                configuration,
                locale: locale,
                snapshot: snapshot,
                translateSegment: translateSegment
            )
        } else {
            guard let runtime = sourceRuntimes[source] else { return snapshot }
            guard sourceRuntimes.count > 1 else {
                throw RecordingSessionControllerError.noAudioSource
            }
            return try await removeSource(runtime, snapshot: snapshot)
        }
    }

    func addSource(
        _ configuration: SourceConfiguration,
        locale: Locale,
        snapshot: Snapshot,
        translateSegment: ProgressiveSegmentTranslationHandler?
    ) async throws -> Snapshot {
        let preparation = try await prepareSourcePipeline(
            configuration,
            locale: locale,
            snapshot: snapshot,
            translateSegment: translateSegment
        )
        return try await activateAddedSource(preparation, locale: locale, snapshot: snapshot)
    }

    private func prepareSourcePipeline(
        _ configuration: SourceConfiguration,
        locale: Locale,
        snapshot: Snapshot,
        translateSegment: ProgressiveSegmentTranslationHandler?
    ) async throws -> SourcePipelinePreparation {
        let source = configuration.source
        guard await captureFactory.requestPermission(for: source) else {
            throw Self.permissionError(for: source)
        }
        try await batchRecording?.prepare(source: source)
        let batchFormat = batchRecording?.targetFormat
        let preparedRecognition = try await prepareRecognitionForNewPipeline(
            source: source,
            sourceFormat: batchFormat,
            locale: locale,
            snapshot: snapshot,
            translateSegment: translateSegment
        )
        guard let captureFormat = batchFormat ?? preparedRecognition?.analyzerFormat else {
            throw AudioCaptureError.converterCreationFailed
        }
        return SourcePipelinePreparation(
            source: source,
            pipeline: AudioSourcePipeline(
                source: source,
                captureFormat: captureFormat,
                captureDeviceID: configuration.captureDeviceID,
                captureBufferSize: configuration.captureBufferSize,
                sessionRelativeOrigin: .zero
            ),
            preparedRecognition: preparedRecognition
        )
    }

    private func activateAddedSource(
        _ preparation: SourcePipelinePreparation,
        locale: Locale,
        snapshot: Snapshot
    ) async throws -> Snapshot {
        var attachment = RecognitionAttachment(
            preparedRecognition: preparation.preparedRecognition,
            recognition: nil
        )
        var runtimeID: UUID?
        var capture: (any AudioCaptureSession)?
        var batchRangeOrigin: BatchRecordingRangeOrigin?
        do {
            batchRangeOrigin = try await beginBatchRange(
                for: preparation,
                locale: locale,
                snapshot: snapshot,
                continuingFromActiveRange: false
            )
            attachment = try await attachRecognition(
                preparation.preparedRecognition,
                to: preparation.pipeline,
                source: preparation.source,
                snapshot: snapshot
            )
            let newRuntimeID = try beginSourceRuntimeGeneration(
                source: preparation.source,
                sessionId: snapshot.sessionId
            )
            runtimeID = newRuntimeID
            let newCapture = captureFactory.makeSession(
                for: preparation.pipeline,
                onUnexpectedStop: captureFailureHandler(
                    source: preparation.source,
                    runtimeID: newRuntimeID,
                    sessionId: snapshot.sessionId
                )
            )
            capture = newCapture
            sourceRuntimes[preparation.source] = SourceRuntime(
                id: newRuntimeID,
                pipeline: preparation.pipeline,
                capture: newCapture,
                recognition: attachment.recognition,
                batchRangeOrigin: batchRangeOrigin
            )
            try await newCapture.start()
            try requireCurrentSourceRuntime(
                source: preparation.source,
                runtimeID: newRuntimeID,
                sessionId: snapshot.sessionId
            )
            return try commitCurrentSources(
                sessionId: snapshot.sessionId,
                expectedSource: preparation.source,
                runtimeID: newRuntimeID
            )
        } catch {
            await rollbackAddedSource(
                preparation,
                attachment: attachment,
                runtimeID: runtimeID,
                capture: capture,
                didBeginBatchRange: batchRangeOrigin != nil,
                sessionId: snapshot.sessionId
            )
            throw error
        }
    }

    private func rollbackAddedSource(
        _ preparation: SourcePipelinePreparation,
        attachment: RecognitionAttachment,
        runtimeID: UUID?,
        capture: (any AudioCaptureSession)?,
        didBeginBatchRange: Bool,
        sessionId: UUID
    ) async {
        if let runtimeID,
           sourceRuntimes[preparation.source]?.id == runtimeID {
            sourceRuntimes[preparation.source] = nil
        }
        try? await capture?.stop()
        preparation.pipeline.router.removeAllConsumers()
        await preparation.pipeline.router.waitUntilIdle()
        if let prepared = attachment.preparedRecognition {
            discardPreparedRecognition(prepared, source: preparation.source, sessionId: sessionId)
        }
        await attachment.recognition?.cancel()
        if attachment.recognition == nil {
            await attachment.preparedRecognition?.session.cancel()
        }
        if didBeginBatchRange {
            try? await batchRecording?.endRangeForReconfiguration(source: preparation.source)
        }
    }

    private func beginBatchRange(
        for preparation: SourcePipelinePreparation,
        locale: Locale,
        snapshot: Snapshot,
        continuingFromActiveRange: Bool
    ) async throws -> BatchRecordingRangeOrigin? {
        let captureOriginDate = Date.now
        guard let batchRecording else {
            preparation.pipeline.setSessionRelativeOrigin(
                seconds: captureOriginDate.timeIntervalSince(snapshot.startedAt)
            )
            return nil
        }
        let attachment = try await batchRecording.beginRangeConsumer(
            source: preparation.source,
            locale: locale,
            at: captureOriginDate,
            continuingFromActiveRange: continuingFromActiveRange
        )
        preparation.pipeline.setSessionRelativeOrigin(seconds: attachment.origin.sessionRelativeOriginSeconds)
        preparation.pipeline.router.setBatchConsumer(attachment.consumer)
        return attachment.origin
    }

    private func attachRecognition(
        _ prepared: PreparedProgressiveRecognitionSession?,
        to pipeline: AudioSourcePipeline,
        source: RecordingAudioSource,
        snapshot: Snapshot
    ) async throws -> RecognitionAttachment {
        guard let prepared else {
            return RecognitionAttachment(preparedRecognition: nil, recognition: nil)
        }
        let recognition = try await attachPreparedRecognition(
            prepared,
            to: pipeline,
            source: source,
            snapshot: snapshot
        )
        guard let recognition else {
            return RecognitionAttachment(preparedRecognition: nil, recognition: nil)
        }
        return RecognitionAttachment(preparedRecognition: prepared, recognition: recognition)
    }

    private func commitCurrentSources(
        sessionId: UUID,
        expectedSource: RecordingAudioSource? = nil,
        runtimeID: UUID? = nil
    ) throws -> Snapshot {
        guard case var .capturing(snapshot) = state,
              snapshot.sessionId == sessionId else {
            throw RecordingSessionControllerError.sessionNotActive
        }
        if let expectedSource,
           let runtimeID,
           sourceRuntimes[expectedSource]?.id != runtimeID {
            throw RecordingSessionControllerError.sessionNotActive
        }
        snapshot.enabledSources = Set(sourceRuntimes.keys)
        transition(to: .capturing(snapshot))
        return snapshot
    }

    private func replaceSource(
        _ previousRuntime: SourceRuntime,
        with configuration: SourceConfiguration,
        locale: Locale,
        snapshot: Snapshot,
        translateSegment: ProgressiveSegmentTranslationHandler?
    ) async throws -> Snapshot {
        let preparation = try await prepareSourcePipeline(
            configuration,
            locale: locale,
            snapshot: snapshot,
            translateSegment: translateSegment
        )
        try await activateReplacement(
            previousRuntime,
            preparation: preparation,
            locale: locale,
            snapshot: snapshot
        )
        await retirePreviousRuntime(previousRuntime, finalMode: snapshot.plan.finalMode)

        guard case let .capturing(finalSnapshot) = state,
              finalSnapshot.sessionId == snapshot.sessionId else {
            throw RecordingSessionControllerError.sessionNotActive
        }
        return finalSnapshot
    }

    private func activateReplacement(
        _ previousRuntime: SourceRuntime,
        preparation: SourcePipelinePreparation,
        locale: Locale,
        snapshot: Snapshot
    ) async throws {
        var attachment = RecognitionAttachment(
            preparedRecognition: preparation.preparedRecognition,
            recognition: nil
        )
        var runtimeID: UUID?
        var capture: (any AudioCaptureSession)?
        var didAttemptPreviousCaptureStop = false
        var batchRangeOrigin: BatchRecordingRangeOrigin?
        do {
            guard sourceRuntimes[preparation.source]?.id == previousRuntime.id else {
                throw RecordingSessionControllerError.sessionNotActive
            }
            let replacementRuntimeID = try beginSourceRuntimeGeneration(
                source: preparation.source,
                sessionId: snapshot.sessionId
            )
            runtimeID = replacementRuntimeID
            let replacementCapture = captureFactory.makeSession(
                for: preparation.pipeline,
                onUnexpectedStop: captureFailureHandler(
                    source: preparation.source,
                    runtimeID: replacementRuntimeID,
                    sessionId: snapshot.sessionId
                )
            )
            capture = replacementCapture

            didAttemptPreviousCaptureStop = true
            try await previousRuntime.capture.stop()
            if batchRecording != nil {
                previousRuntime.pipeline.router.setBatchConsumer(nil)
                await previousRuntime.pipeline.router.waitUntilIdle()
            }
            try requirePreviousRuntimeDuringReplacement(
                previousRuntime,
                source: preparation.source,
                replacementRuntimeID: replacementRuntimeID,
                sessionId: snapshot.sessionId
            )
            batchRangeOrigin = try await beginBatchRange(
                for: preparation,
                locale: locale,
                snapshot: snapshot,
                continuingFromActiveRange: true
            )
            attachment = try await attachRecognition(
                preparation.preparedRecognition,
                to: preparation.pipeline,
                source: preparation.source,
                snapshot: snapshot
            )

            sourceRuntimes[preparation.source] = SourceRuntime(
                id: replacementRuntimeID,
                pipeline: preparation.pipeline,
                capture: replacementCapture,
                recognition: attachment.recognition,
                batchRangeOrigin: batchRangeOrigin
            )
            try await replacementCapture.start()
            try requireCurrentSourceRuntime(
                source: preparation.source,
                runtimeID: replacementRuntimeID,
                sessionId: snapshot.sessionId
            )
            _ = try commitCurrentSources(
                sessionId: snapshot.sessionId,
                expectedSource: preparation.source,
                runtimeID: replacementRuntimeID
            )
        } catch {
            try await rollbackReplacement(
                previousRuntime,
                preparation: preparation,
                attachment: attachment,
                runtimeID: runtimeID,
                capture: capture,
                didAttemptPreviousCaptureStop: didAttemptPreviousCaptureStop,
                locale: locale,
                sessionId: snapshot.sessionId
            )
            throw error
        }
    }

    private func rollbackReplacement(
        _ previousRuntime: SourceRuntime,
        preparation: SourcePipelinePreparation,
        attachment: RecognitionAttachment,
        runtimeID: UUID?,
        capture: (any AudioCaptureSession)?,
        didAttemptPreviousCaptureStop: Bool,
        locale: Locale,
        sessionId: UUID
    ) async throws {
        if let runtimeID,
           sourceRuntimes[preparation.source]?.id == runtimeID {
            sourceRuntimes[preparation.source] = nil
        } else if sourceRuntimes[preparation.source]?.id == previousRuntime.id {
            if didAttemptPreviousCaptureStop {
                sourceRuntimes[preparation.source] = nil
            } else {
                sourceRuntimeGenerations[preparation.source] = previousRuntime.id
            }
        }
        try? await capture?.stop()
        preparation.pipeline.router.removeAllConsumers()
        await preparation.pipeline.router.waitUntilIdle()
        if let prepared = attachment.preparedRecognition {
            discardPreparedRecognition(prepared, source: preparation.source, sessionId: sessionId)
        }
        await attachment.recognition?.cancel()
        if attachment.recognition == nil {
            await attachment.preparedRecognition?.session.cancel()
        }
        guard didAttemptPreviousCaptureStop else { return }
        let restoredRangeOrigin = await restoreBatchRangeIfNeeded(previousRuntime, locale: locale)
        try await restorePreviousRuntime(
            previousRuntime,
            source: preparation.source,
            batchRangeOrigin: restoredRangeOrigin ?? previousRuntime.batchRangeOrigin,
            sessionId: sessionId
        )
    }

    private func restoreBatchRangeIfNeeded(
        _ previousRuntime: SourceRuntime,
        locale: Locale
    ) async -> BatchRecordingRangeOrigin? {
        guard let batchRecording else { return nil }
        let source = previousRuntime.pipeline.source
        previousRuntime.pipeline.router.setBatchConsumer(nil)
        await previousRuntime.pipeline.router.waitUntilIdle()
        do {
            let attachment = try await batchRecording.beginRangeConsumer(
                source: source,
                locale: locale,
                at: .now,
                continuingFromActiveRange: false
            )
            previousRuntime.pipeline.router.setBatchConsumer(attachment.consumer)
            return attachment.origin
        } catch {
            previousRuntime.pipeline.router.setBatchConsumer(nil)
            if batchRuntimeFailureMessage == nil {
                batchRuntimeFailureMessage = error.localizedDescription
            }
            await onRuntimeFailure?(source, error.localizedDescription, false)
            return nil
        }
    }

    private func retirePreviousRuntime(
        _ previousRuntime: SourceRuntime,
        finalMode: TranscriptionMode
    ) async {
        let source = previousRuntime.pipeline.source
        previousRuntime.pipeline.router.removeAllConsumers()
        await previousRuntime.pipeline.router.waitUntilIdle()
        if finalMode == .realtime {
            do {
                try await previousRuntime.recognition?.finish()
            } catch {
                await onRuntimeFailure?(source, error.localizedDescription, true)
            }
        } else {
            await previousRuntime.recognition?.cancel()
        }
    }

    private func removeSource(
        _ runtime: SourceRuntime,
        snapshot: Snapshot
    ) async throws -> Snapshot {
        let source = runtime.pipeline.source
        guard sourceRuntimes[source]?.id == runtime.id else {
            throw RecordingSessionControllerError.sessionNotActive
        }
        sourceRuntimes[source] = nil
        var currentSnapshot = snapshot
        currentSnapshot.enabledSources = Set(sourceRuntimes.keys)
        transition(to: .capturing(currentSnapshot))

        do {
            try await runtime.capture.stop()
        } catch {
            await onRuntimeFailure?(source, error.localizedDescription, false)
        }
        runtime.pipeline.router.removeAllConsumers()
        await runtime.pipeline.router.waitUntilIdle()
        if snapshot.plan.finalMode == .realtime {
            do {
                try await runtime.recognition?.finish()
            } catch {
                await onRuntimeFailure?(source, error.localizedDescription, true)
            }
        } else {
            await runtime.recognition?.cancel()
        }
        do {
            try await batchRecording?.endRangeForReconfiguration(source: source)
        } catch {
            await onRuntimeFailure?(source, error.localizedDescription, false)
        }

        guard case let .capturing(finalSnapshot) = state,
              finalSnapshot.sessionId == snapshot.sessionId else {
            throw RecordingSessionControllerError.sessionNotActive
        }
        return finalSnapshot
    }

    private func prepareRecognitionForNewPipeline(
        source: RecordingAudioSource,
        sourceFormat: AVAudioFormat?,
        locale: Locale,
        snapshot: Snapshot,
        translateSegment: ProgressiveSegmentTranslationHandler?
    ) async throws -> PreparedProgressiveRecognitionSession? {
        guard snapshot.plan.requiresLiveRecognition else { return nil }
        var prepared: PreparedProgressiveRecognitionSession?
        do {
            try await recognitionFactory.prepareModel(locale: locale)
            let newRecognition = try await recognitionFactory.prepareSession(
                locale: locale,
                source: source,
                sourceFormat: sourceFormat,
                bufferingMode: snapshot.plan.recordsBatchAudio
                    ? .lowLatency(maximumInputCount: 64)
                    : .lossless,
                translateSegment: translateSegment
            )
            prepared = newRecognition
            try await startRecognition(newRecognition.session, source: source, snapshot: snapshot)
            try requirePendingRecognitionStartSucceeded(
                pipelineID: newRecognition.session.pipelineID,
                source: source,
                sessionId: snapshot.sessionId
            )
            return newRecognition
        } catch {
            if let prepared {
                discardPreparedRecognition(
                    prepared,
                    source: source,
                    sessionId: snapshot.sessionId
                )
                await prepared.session.cancel()
            }
            guard snapshot.plan.finalMode == .batch else { throw error }
            await onRuntimeFailure?(source, error.localizedDescription, false)
            return nil
        }
    }

    private func attachPreparedRecognition(
        _ prepared: PreparedProgressiveRecognitionSession,
        to pipeline: AudioSourcePipeline,
        source: RecordingAudioSource,
        snapshot: Snapshot
    ) async throws -> (any ProgressiveRecognitionSession)? {
        do {
            try requirePendingRecognitionStartSucceeded(
                pipelineID: prepared.session.pipelineID,
                source: source,
                sessionId: snapshot.sessionId
            )
            try consumePendingRecognitionStart(
                pipelineID: prepared.session.pipelineID,
                source: source,
                sessionId: snapshot.sessionId
            )
            pipeline.router.setLiveConsumer(
                prepared.session.liveConsumer,
                bufferingMode: snapshot.plan.recordsBatchAudio
                    ? .lowLatency(maximumFrameCount: 8)
                    : .lossless,
                onFailure: liveFailureHandler(
                    source: source,
                    pipelineID: prepared.session.pipelineID,
                    sessionId: snapshot.sessionId
                )
            )
            return prepared.session
        } catch {
            discardPreparedRecognition(prepared, source: source, sessionId: snapshot.sessionId)
            await prepared.session.cancel()
            guard snapshot.plan.finalMode == .batch else { throw error }
            await onRuntimeFailure?(source, error.localizedDescription, false)
            return nil
        }
    }

    private func discardPreparedRecognition(
        _ prepared: PreparedProgressiveRecognitionSession,
        source: RecordingAudioSource,
        sessionId: UUID
    ) {
        discardPendingRecognitionStart(
            pipelineID: prepared.session.pipelineID,
            source: source,
            sessionId: sessionId
        )
    }

    private func requirePreviousRuntimeDuringReplacement(
        _ previousRuntime: SourceRuntime,
        source: RecordingAudioSource,
        replacementRuntimeID: UUID,
        sessionId: UUID
    ) throws {
        guard case let .capturing(snapshot) = state,
              snapshot.sessionId == sessionId,
              sourceRuntimeGenerations[source] == replacementRuntimeID,
              sourceRuntimes[source]?.id == previousRuntime.id else {
            throw RecordingSessionControllerError.sessionNotActive
        }
    }

    private func restorePreviousRuntime(
        _ previousRuntime: SourceRuntime,
        source: RecordingAudioSource,
        batchRangeOrigin: BatchRecordingRangeOrigin?,
        sessionId: UUID
    ) async throws {
        guard case var .capturing(snapshot) = state,
              snapshot.sessionId == sessionId,
              sourceRuntimes[source] == nil else {
            throw RecordingSessionControllerError.sessionNotActive
        }
        sourceRuntimeGenerations[source] = previousRuntime.id
        var restoredRuntime = previousRuntime
        restoredRuntime.batchRangeOrigin = batchRangeOrigin
        sourceRuntimes[source] = restoredRuntime
        do {
            try await previousRuntime.capture.start()
            try requireCurrentSourceRuntime(
                source: source,
                runtimeID: previousRuntime.id,
                sessionId: sessionId
            )
            guard case var .capturing(currentSnapshot) = state,
                  currentSnapshot.sessionId == sessionId else {
                throw RecordingSessionControllerError.sessionNotActive
            }
            currentSnapshot.enabledSources = Set(sourceRuntimes.keys)
            transition(to: .capturing(currentSnapshot))
        } catch {
            if sourceRuntimes[source]?.id == previousRuntime.id {
                sourceRuntimes[source] = nil
            }
            snapshot.enabledSources = Set(sourceRuntimes.keys)
            transition(to: .capturing(snapshot))
            await onRuntimeFailure?(source, error.localizedDescription, snapshot.enabledSources.isEmpty)
            throw error
        }
    }
}
