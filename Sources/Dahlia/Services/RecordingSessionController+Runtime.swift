import Foundation

extension RecordingSessionController {
    func startRecognition(
        _ recognition: any ProgressiveRecognitionSession,
        source: RecordingAudioSource,
        snapshot: Snapshot
    ) async throws {
        guard let onEvent else {
            throw RecordingSessionControllerError.sessionNotPrepared
        }
        let pipelineID = recognition.pipelineID
        pendingRecognitionStarts[pipelineID] = PendingRecognitionStart(
            source: source,
            sessionId: snapshot.sessionId,
            failureMessage: nil
        )
        do {
            try await recognition.start(
                recordingStartTime: snapshot.startedAt,
                recordingSessionId: snapshot.sessionId
            ) { [weak self] event in
                await onEvent(event)
                guard case .failure = event else { return }
                await self?.recognitionDidFail(
                    event,
                    expectedPipelineID: pipelineID,
                    expectedSource: source,
                    sessionId: snapshot.sessionId
                )
            }
        } catch {
            discardPendingRecognitionStart(
                pipelineID: pipelineID,
                source: source,
                sessionId: snapshot.sessionId
            )
            throw error
        }
    }

    /// start は成功したものの runtime へまだ attach されていない認識器を確定する。
    /// start 中の failure event はここで同期的に失敗へ変換し、壊れた認識器の swap を防ぐ。
    func consumePendingRecognitionStart(
        pipelineID: UUID,
        source: RecordingAudioSource,
        sessionId: UUID
    ) throws {
        let pending = try requirePendingRecognitionStart(
            pipelineID: pipelineID,
            source: source,
            sessionId: sessionId
        )
        pendingRecognitionStarts[pipelineID] = nil
        try throwPendingRecognitionFailureIfNeeded(pending)
    }

    func requirePendingRecognitionStartSucceeded(
        pipelineID: UUID,
        source: RecordingAudioSource,
        sessionId: UUID
    ) throws {
        let pending = try requirePendingRecognitionStart(
            pipelineID: pipelineID,
            source: source,
            sessionId: sessionId
        )
        try throwPendingRecognitionFailureIfNeeded(pending)
    }

    func discardPendingRecognitionStart(
        pipelineID: UUID,
        source: RecordingAudioSource,
        sessionId: UUID
    ) {
        guard let pending = pendingRecognitionStarts[pipelineID],
              pending.source == source,
              pending.sessionId == sessionId else { return }
        pendingRecognitionStarts[pipelineID] = nil
    }

    func recognitionDidFail(
        _ event: TranscriptionEvent,
        expectedPipelineID: UUID,
        expectedSource: RecordingAudioSource,
        sessionId: UUID
    ) async {
        guard case let .failure(eventSessionId, pipelineID, _, message) = event,
              eventSessionId == sessionId,
              pipelineID == expectedPipelineID else { return }

        if var pending = pendingRecognitionStarts[pipelineID],
           pending.source == expectedSource,
           pending.sessionId == sessionId {
            if pending.failureMessage == nil {
                pending.failureMessage = message
                pendingRecognitionStarts[pipelineID] = pending
            }
            return
        }

        guard case let .capturing(snapshot) = state,
              snapshot.sessionId == sessionId,
              let runtime = sourceRuntimes[expectedSource],
              runtime.recognition?.pipelineID == expectedPipelineID else { return }

        if snapshot.plan.finalMode == .batch {
            let runtimeID = runtime.id
            await runtime.pipeline.router.removeLiveConsumerAndWait()
            await runtime.recognition?.cancel()
            guard var currentRuntime = sourceRuntimes[expectedSource],
                  currentRuntime.id == runtimeID,
                  currentRuntime.recognition?.pipelineID == expectedPipelineID else { return }
            currentRuntime.recognition = nil
            sourceRuntimes[expectedSource] = currentRuntime
            await onRuntimeFailure?(expectedSource, message, false)
        } else {
            await onRuntimeFailure?(expectedSource, message, true)
        }
    }

    func handleUnexpectedCaptureStop(
        source: RecordingAudioSource,
        runtimeID: UUID,
        sessionId: UUID,
        message: String
    ) async {
        guard case let .capturing(snapshot) = state,
              snapshot.sessionId == sessionId,
              sourceRuntimeGenerations[source] == runtimeID,
              sourceRuntimes[source]?.id == runtimeID else { return }

        await stopSource(source, expectedRuntimeID: runtimeID, finalMode: snapshot.plan.finalMode)
        guard sourceRuntimeGenerations[source] == runtimeID,
              sourceRuntimes[source] == nil else { return }
        try? await batchRecording?.endRangeForReconfiguration(source: source)
        guard case var .capturing(currentSnapshot) = state,
              currentSnapshot.sessionId == sessionId,
              sourceRuntimeGenerations[source] == runtimeID,
              sourceRuntimes[source] == nil else { return }
        currentSnapshot.enabledSources.remove(source)
        transition(to: .capturing(currentSnapshot))
        await onRuntimeFailure?(source, message, currentSnapshot.enabledSources.isEmpty)
    }

    func stopSource(
        _ source: RecordingAudioSource,
        expectedRuntimeID: UUID? = nil,
        finalMode: TranscriptionMode
    ) async {
        guard let runtime = sourceRuntimes[source],
              expectedRuntimeID == nil || runtime.id == expectedRuntimeID else { return }
        sourceRuntimes[source] = nil
        try? await runtime.capture.stop()
        runtime.pipeline.router.removeAllConsumers()
        await runtime.pipeline.router.waitUntilIdle()
        if finalMode == .realtime {
            try? await runtime.recognition?.finish()
        } else {
            await runtime.recognition?.cancel()
        }
    }

    func cleanupActiveResources(
        cancelRecognition: Bool,
        deleteBatchRecording: Bool
    ) async {
        for source in Self.sortedSources(sourceRuntimes.keys) {
            try? await sourceRuntimes[source]?.capture.stop()
        }
        for runtime in sourceRuntimes.values {
            runtime.pipeline.router.removeAllConsumers()
        }
        for runtime in sourceRuntimes.values {
            await runtime.pipeline.router.waitUntilIdle()
            if cancelRecognition {
                await runtime.recognition?.cancel()
            } else {
                try? await runtime.recognition?.finish()
            }
        }
        sourceRuntimes.removeAll()
        sourceRuntimeGenerations.removeAll()
        pendingRecognitionStarts.removeAll()
        if deleteBatchRecording {
            await batchRecording?.cancelAndDelete()
        }
        batchRecording = nil
    }

    func liveFailureHandler(
        source: RecordingAudioSource,
        pipelineID: UUID,
        sessionId: UUID
    ) -> AudioFrameRouter.LiveFailureHandler {
        { [weak self] in
            Task {
                await self?.liveConsumerDidFail(
                    source: source,
                    pipelineID: pipelineID,
                    sessionId: sessionId
                )
            }
        }
    }

    func liveConsumerDidFail(
        source: RecordingAudioSource,
        pipelineID: UUID,
        sessionId: UUID
    ) async {
        guard case let .capturing(snapshot) = state,
              snapshot.sessionId == sessionId,
              let runtime = sourceRuntimes[source],
              runtime.recognition?.pipelineID == pipelineID else { return }
        if snapshot.plan.finalMode == .batch {
            let runtimeID = runtime.id
            await runtime.recognition?.cancel()
            guard var currentRuntime = sourceRuntimes[source],
                  currentRuntime.id == runtimeID,
                  currentRuntime.recognition?.pipelineID == pipelineID else { return }
            currentRuntime.recognition = nil
            sourceRuntimes[source] = currentRuntime
            await onRuntimeFailure?(source, L10n.liveSubtitleConversionFailed, false)
        } else {
            await onRuntimeFailure?(source, L10n.liveSubtitleConversionFailed, true)
        }
    }

    func captureFailureHandler(
        source: RecordingAudioSource,
        runtimeID: UUID,
        sessionId: UUID
    ) -> AudioCaptureUnexpectedStopHandler {
        { [weak self] error in
            let message = error?.localizedDescription ?? L10n.systemAudioCaptureStopped
            Task {
                await self?.handleUnexpectedCaptureStop(
                    source: source,
                    runtimeID: runtimeID,
                    sessionId: sessionId,
                    message: message
                )
            }
        }
    }

    func beginSourceRuntimeGeneration(
        source: RecordingAudioSource,
        sessionId: UUID
    ) throws -> UUID {
        guard case let .capturing(snapshot) = state,
              snapshot.sessionId == sessionId else {
            throw RecordingSessionControllerError.sessionNotActive
        }
        let runtimeID = UUID.v7()
        sourceRuntimeGenerations[source] = runtimeID
        return runtimeID
    }

    func requireCurrentSourceRuntimeGeneration(
        source: RecordingAudioSource,
        runtimeID: UUID,
        sessionId: UUID
    ) throws {
        guard case let .capturing(snapshot) = state,
              snapshot.sessionId == sessionId,
              sourceRuntimeGenerations[source] == runtimeID else {
            throw RecordingSessionControllerError.sessionNotActive
        }
    }

    func requireCurrentSourceRuntime(
        source: RecordingAudioSource,
        runtimeID: UUID,
        sessionId: UUID
    ) throws {
        try requireCurrentSourceRuntimeGeneration(
            source: source,
            runtimeID: runtimeID,
            sessionId: sessionId
        )
        guard sourceRuntimes[source]?.id == runtimeID else {
            throw RecordingSessionControllerError.sessionNotActive
        }
    }

    private func requirePendingRecognitionStart(
        pipelineID: UUID,
        source: RecordingAudioSource,
        sessionId: UUID
    ) throws -> PendingRecognitionStart {
        guard let pending = pendingRecognitionStarts[pipelineID],
              pending.source == source,
              pending.sessionId == sessionId else {
            throw RecordingSessionControllerError.sessionNotActive
        }
        return pending
    }

    private func throwPendingRecognitionFailureIfNeeded(
        _ pending: PendingRecognitionStart
    ) throws {
        if let failureMessage = pending.failureMessage {
            throw RecordingSessionControllerError.recognitionFailed(failureMessage)
        }
    }
}
