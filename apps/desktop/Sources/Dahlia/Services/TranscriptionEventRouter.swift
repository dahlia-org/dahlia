/// 1つの逐次認識イベントを、セッションプランに応じた保存先へ分配する。
enum TranscriptionEventRouter {
    @MainActor
    static func routeTranscriptProjection(
        _ event: TranscriptionEvent,
        plan: TranscriptionSessionPlan,
        transcriptStore: TranscriptStore
    ) {
        guard plan.persistsRealtimeTranscript else { return }
        apply(event, to: transcriptStore)
    }

    @MainActor
    static func routeLiveCaption(
        _ event: TranscriptionEvent,
        plan: TranscriptionSessionPlan,
        liveCaptionStore: LiveCaptionStore
    ) {
        if plan.liveSubtitlesEnabled {
            liveCaptionStore.apply(event: event)
            return
        }

        guard plan.persistsRealtimeTranscript,
              liveCaptionStore.activeSessionId != nil else { return }
        switch event {
        case .finalized, .clearPreview, .translation:
            liveCaptionStore.apply(event: event)
        case .preview, .previewTranslation, .failure:
            break
        }
    }

    @MainActor
    private static func apply(_ event: TranscriptionEvent, to store: TranscriptStore) {
        switch event {
        case let .preview(segment):
            store.updateUnconfirmedSegment(segment, forSource: segment.audioSource)
        case let .finalized(segment):
            store.finalizeSegment(segment, forSource: segment.audioSource)
        case let .clearPreview(_, sourceLabel):
            store.clearUnconfirmedSegments(forSource: sourceLabel)
        case let .previewTranslation(_, segmentID, translatedText),
             let .translation(_, segmentID, translatedText):
            store.updateTranslatedText(for: segmentID, translatedText: translatedText)
        case .failure:
            break
        }
    }
}
