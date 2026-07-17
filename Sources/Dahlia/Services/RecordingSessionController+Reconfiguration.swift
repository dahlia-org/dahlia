@preconcurrency import AVFoundation
import CoreMedia
import Foundation

extension RecordingSessionController {
    private struct LocaleRecognitionReplacement {
        let prepared: PreparedProgressiveRecognitionSession
        let runtimeID: UUID
    }

    private struct RetiredRecognition {
        let source: RecordingAudioSource
        let router: AudioFrameRouter
        let recognition: any ProgressiveRecognitionSession
    }

    /// realtimeでは認識器を維持して投影だけ変更し、batchではlive認識をattach/detachする。
    func setLiveSubtitlesEnabled(
        _ isEnabled: Bool,
        translateSegment: ProgressiveSegmentTranslationHandler?
    ) async throws -> Snapshot {
        guard case let .capturing(snapshot) = state else {
            throw RecordingSessionControllerError.sessionNotActive
        }
        guard snapshot.plan.liveSubtitlesEnabled != isEnabled else { return snapshot }

        if snapshot.plan.finalMode == .batch, isEnabled {
            try await enableBatchLiveRecognition(
                snapshot: snapshot,
                translateSegment: translateSegment
            )
        } else if snapshot.plan.finalMode == .batch {
            await disableBatchLiveRecognition()
        }

        return try commitLiveSubtitleState(isEnabled, sessionId: snapshot.sessionId)
    }

    private func enableBatchLiveRecognition(
        snapshot: Snapshot,
        translateSegment: ProgressiveSegmentTranslationHandler?
    ) async throws {
        guard let locale = currentLocale else {
            throw RecordingSessionControllerError.sessionNotPrepared
        }
        do {
            try await recognitionFactory.prepareModel(locale: locale)
        } catch {
            await onRuntimeFailure?(nil, error.localizedDescription, false)
            throw error
        }

        var attachedCount = 0
        var firstFailureMessage: String?
        for source in Self.sortedSources(sourceRuntimes.keys) {
            do {
                if try await attachBatchLiveRecognition(
                    source: source,
                    locale: locale,
                    snapshot: snapshot,
                    translateSegment: translateSegment
                ) {
                    attachedCount += 1
                }
            } catch {
                firstFailureMessage = firstFailureMessage ?? error.localizedDescription
                await onRuntimeFailure?(source, error.localizedDescription, false)
            }
        }
        guard attachedCount > 0 else {
            throw RecordingSessionControllerError.recognitionFailed(
                firstFailureMessage ?? L10n.speechRecognitionNotReady
            )
        }
    }

    private func attachBatchLiveRecognition(
        source: RecordingAudioSource,
        locale: Locale,
        snapshot: Snapshot,
        translateSegment: ProgressiveSegmentTranslationHandler?
    ) async throws -> Bool {
        guard let initialRuntime = sourceRuntimes[source] else { return false }
        guard initialRuntime.recognition == nil else { return true }
        var prepared: PreparedProgressiveRecognitionSession?
        do {
            let newRecognition = try await recognitionFactory.prepareSession(
                locale: locale,
                source: source,
                sourceFormat: initialRuntime.pipeline.captureFormat,
                bufferingMode: .lowLatency(maximumInputCount: 64),
                translateSegment: translateSegment
            )
            prepared = newRecognition
            try await startRecognition(newRecognition.session, source: source, snapshot: snapshot)
            try attachStartedBatchRecognition(
                newRecognition,
                source: source,
                runtimeID: initialRuntime.id,
                sessionId: snapshot.sessionId
            )
            return true
        } catch {
            if let prepared {
                discardPendingRecognitionStart(
                    pipelineID: prepared.session.pipelineID,
                    source: source,
                    sessionId: snapshot.sessionId
                )
                await prepared.session.cancel()
            }
            throw error
        }
    }

    private func attachStartedBatchRecognition(
        _ prepared: PreparedProgressiveRecognitionSession,
        source: RecordingAudioSource,
        runtimeID: UUID,
        sessionId: UUID
    ) throws {
        try requireCurrentSourceRuntime(source: source, runtimeID: runtimeID, sessionId: sessionId)
        try requirePendingRecognitionStartSucceeded(
            pipelineID: prepared.session.pipelineID,
            source: source,
            sessionId: sessionId
        )
        try consumePendingRecognitionStart(
            pipelineID: prepared.session.pipelineID,
            source: source,
            sessionId: sessionId
        )
        guard var runtime = sourceRuntimes[source], runtime.id == runtimeID else {
            throw RecordingSessionControllerError.sessionNotActive
        }
        runtime.recognition = prepared.session
        sourceRuntimes[source] = runtime
        runtime.pipeline.router.setLiveConsumer(
            prepared.session.liveConsumer,
            bufferingMode: .lowLatency(maximumFrameCount: 8),
            onFailure: liveFailureHandler(
                source: source,
                pipelineID: prepared.session.pipelineID,
                sessionId: sessionId
            )
        )
    }

    private func disableBatchLiveRecognition() async {
        for source in Self.sortedSources(sourceRuntimes.keys) {
            guard let runtime = sourceRuntimes[source] else { continue }
            let runtimeID = runtime.id
            let pipelineID = runtime.recognition?.pipelineID
            await runtime.pipeline.router.removeLiveConsumerAndWait()
            await runtime.recognition?.cancel()
            guard var currentRuntime = sourceRuntimes[source],
                  currentRuntime.id == runtimeID,
                  currentRuntime.recognition?.pipelineID == pipelineID else { continue }
            currentRuntime.recognition = nil
            sourceRuntimes[source] = currentRuntime
        }
    }

    private func commitLiveSubtitleState(_ isEnabled: Bool, sessionId: UUID) throws -> Snapshot {
        guard case var .capturing(snapshot) = state,
              snapshot.sessionId == sessionId else {
            throw RecordingSessionControllerError.sessionNotActive
        }
        snapshot.plan.liveSubtitlesEnabled = isEnabled
        transition(to: .capturing(snapshot))
        return snapshot
    }

    /// 新localeの認識器を先に準備・開始し、batch rangeを原子的に切り替えてからswapする。
    func changeLocale(
        to locale: Locale,
        translateSegment: ProgressiveSegmentTranslationHandler?
    ) async throws -> Snapshot {
        guard case let .capturing(snapshot) = state else {
            throw RecordingSessionControllerError.sessionNotActive
        }
        guard snapshot.localeIdentifier != locale.identifier else { return snapshot }

        let prepared = try await prepareLocaleReplacements(
            locale: locale,
            snapshot: snapshot,
            translateSegment: translateSegment
        )
        do {
            try await rotateBatchRanges(to: locale)
        } catch {
            await cancelLocaleReplacements(prepared, sessionId: snapshot.sessionId)
            throw error
        }

        let replacements = try await validateLocaleReplacements(
            prepared,
            snapshot: snapshot
        )
        do {
            try consumeLocaleReplacementStarts(replacements, sessionId: snapshot.sessionId)
        } catch {
            await cancelLocaleReplacements(replacements, sessionId: snapshot.sessionId)
            throw error
        }

        let retired = installLocaleReplacements(replacements, snapshot: snapshot)
        _ = try commitLocale(locale, sessionId: snapshot.sessionId)
        await finishRetiredRecognitions(retired, finalMode: snapshot.plan.finalMode)

        guard case let .capturing(finalSnapshot) = state,
              finalSnapshot.sessionId == snapshot.sessionId else {
            throw RecordingSessionControllerError.sessionNotActive
        }
        return finalSnapshot
    }

    private func prepareLocaleReplacements(
        locale: Locale,
        snapshot: Snapshot,
        translateSegment: ProgressiveSegmentTranslationHandler?
    ) async throws -> [RecordingAudioSource: LocaleRecognitionReplacement] {
        guard snapshot.plan.requiresLiveRecognition else { return [:] }
        guard try await prepareLocaleRecognitionModel(locale, snapshot: snapshot) else { return [:] }

        var replacements: [RecordingAudioSource: LocaleRecognitionReplacement] = [:]
        do {
            for source in Self.sortedSources(sourceRuntimes.keys) {
                if let replacement = try await prepareLocaleReplacement(
                    source: source,
                    locale: locale,
                    snapshot: snapshot,
                    translateSegment: translateSegment
                ) {
                    replacements[source] = replacement
                }
            }
            return replacements
        } catch {
            await cancelLocaleReplacements(replacements, sessionId: snapshot.sessionId)
            throw error
        }
    }

    private func prepareLocaleRecognitionModel(
        _ locale: Locale,
        snapshot: Snapshot
    ) async throws -> Bool {
        do {
            try await recognitionFactory.prepareModel(locale: locale)
            return true
        } catch {
            guard snapshot.plan.finalMode == .batch else { throw error }
            await onRuntimeFailure?(nil, error.localizedDescription, false)
            return false
        }
    }

    private func prepareLocaleReplacement(
        source: RecordingAudioSource,
        locale: Locale,
        snapshot: Snapshot,
        translateSegment: ProgressiveSegmentTranslationHandler?
    ) async throws -> LocaleRecognitionReplacement? {
        guard let runtime = sourceRuntimes[source] else { return nil }
        var prepared: PreparedProgressiveRecognitionSession?
        do {
            let replacement = try await recognitionFactory.prepareSession(
                locale: locale,
                source: source,
                sourceFormat: runtime.pipeline.captureFormat,
                bufferingMode: snapshot.plan.recordsBatchAudio
                    ? .lowLatency(maximumInputCount: 64)
                    : .lossless,
                translateSegment: translateSegment
            )
            prepared = replacement
            try await startRecognition(replacement.session, source: source, snapshot: snapshot)
            try requireCurrentSourceRuntime(
                source: source,
                runtimeID: runtime.id,
                sessionId: snapshot.sessionId
            )
            try requirePendingRecognitionStartSucceeded(
                pipelineID: replacement.session.pipelineID,
                source: source,
                sessionId: snapshot.sessionId
            )
            return LocaleRecognitionReplacement(prepared: replacement, runtimeID: runtime.id)
        } catch {
            if let prepared {
                discardPendingRecognitionStart(
                    pipelineID: prepared.session.pipelineID,
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

    private func rotateBatchRanges(to locale: Locale) async throws {
        guard let batchRecording else { return }
        let origins = sourceRuntimes.values.compactMap(\.batchRangeOrigin)
        let rotatedOrigins = try await batchRecording.rotateRanges(
            origins,
            locale: locale
        )
        for (source, origin) in rotatedOrigins {
            guard var runtime = sourceRuntimes[source] else { continue }
            runtime.batchRangeOrigin = origin
            sourceRuntimes[source] = runtime
        }
    }

    private func validateLocaleReplacements(
        _ replacements: [RecordingAudioSource: LocaleRecognitionReplacement],
        snapshot: Snapshot
    ) async throws -> [RecordingAudioSource: LocaleRecognitionReplacement] {
        var valid: [RecordingAudioSource: LocaleRecognitionReplacement] = [:]
        for source in Self.sortedSources(replacements.keys) {
            guard let replacement = replacements[source] else { continue }
            do {
                try requireCurrentSourceRuntime(
                    source: source,
                    runtimeID: replacement.runtimeID,
                    sessionId: snapshot.sessionId
                )
                try requirePendingRecognitionStartSucceeded(
                    pipelineID: replacement.prepared.session.pipelineID,
                    source: source,
                    sessionId: snapshot.sessionId
                )
                valid[source] = replacement
            } catch {
                discardPendingRecognitionStart(
                    pipelineID: replacement.prepared.session.pipelineID,
                    source: source,
                    sessionId: snapshot.sessionId
                )
                await replacement.prepared.session.cancel()
                if snapshot.plan.finalMode == .realtime {
                    await cancelLocaleReplacements(replacements, sessionId: snapshot.sessionId)
                    throw error
                }
                await onRuntimeFailure?(source, error.localizedDescription, false)
            }
        }
        return valid
    }

    private func consumeLocaleReplacementStarts(
        _ replacements: [RecordingAudioSource: LocaleRecognitionReplacement],
        sessionId: UUID
    ) throws {
        for source in Self.sortedSources(replacements.keys) {
            guard let replacement = replacements[source] else { continue }
            try consumePendingRecognitionStart(
                pipelineID: replacement.prepared.session.pipelineID,
                source: source,
                sessionId: sessionId
            )
        }
    }

    private func installLocaleReplacements(
        _ replacements: [RecordingAudioSource: LocaleRecognitionReplacement],
        snapshot: Snapshot
    ) -> [RetiredRecognition] {
        let detachesMissingRecognition = snapshot.plan.finalMode == .batch
            && snapshot.plan.liveSubtitlesEnabled
        var retired: [RetiredRecognition] = []

        for source in Self.sortedSources(sourceRuntimes.keys) {
            guard var runtime = sourceRuntimes[source] else { continue }
            if let replacement = replacements[source] {
                if let previous = runtime.recognition {
                    retired.append(RetiredRecognition(
                        source: source,
                        router: runtime.pipeline.router,
                        recognition: previous
                    ))
                }
                runtime.recognition = replacement.prepared.session
                runtime.pipeline.router.setLiveConsumer(
                    replacement.prepared.session.liveConsumer,
                    bufferingMode: snapshot.plan.recordsBatchAudio
                        ? .lowLatency(maximumFrameCount: 8)
                        : .lossless,
                    onFailure: liveFailureHandler(
                        source: source,
                        pipelineID: replacement.prepared.session.pipelineID,
                        sessionId: snapshot.sessionId
                    )
                )
            } else if detachesMissingRecognition {
                if let previous = runtime.recognition {
                    retired.append(RetiredRecognition(
                        source: source,
                        router: runtime.pipeline.router,
                        recognition: previous
                    ))
                }
                runtime.recognition = nil
                runtime.pipeline.router.setLiveConsumer(nil)
            }
            sourceRuntimes[source] = runtime
        }
        return retired
    }

    private func commitLocale(_ locale: Locale, sessionId: UUID) throws -> Snapshot {
        guard case var .capturing(snapshot) = state,
              snapshot.sessionId == sessionId else {
            throw RecordingSessionControllerError.sessionNotActive
        }
        snapshot.localeIdentifier = locale.identifier
        snapshot.enabledSources = Set(sourceRuntimes.keys)
        currentLocale = locale
        transition(to: .capturing(snapshot))
        return snapshot
    }

    private func finishRetiredRecognitions(
        _ retired: [RetiredRecognition],
        finalMode: TranscriptionMode
    ) async {
        for previous in retired {
            await previous.router.waitUntilIdle()
            if finalMode == .realtime {
                do {
                    try await previous.recognition.finish()
                } catch {
                    await onRuntimeFailure?(previous.source, error.localizedDescription, true)
                }
            } else {
                await previous.recognition.cancel()
            }
        }
    }

    private func cancelLocaleReplacements(
        _ replacements: [RecordingAudioSource: LocaleRecognitionReplacement],
        sessionId: UUID
    ) async {
        for (source, replacement) in replacements {
            discardPendingRecognitionStart(
                pipelineID: replacement.prepared.session.pipelineID,
                source: source,
                sessionId: sessionId
            )
            await replacement.prepared.session.cancel()
        }
    }

}
