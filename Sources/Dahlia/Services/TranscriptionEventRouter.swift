/// 1つの逐次認識イベントを、セッションプランに応じた保存先へ分配する。
enum TranscriptionEventRouter {
    @MainActor
    static func route(
        _ event: TranscriptionEvent,
        plan: TranscriptionSessionPlan,
        transcriptStore: TranscriptStore,
        liveCaptionStore: LiveCaptionStore
    ) {
        if plan.persistsRealtimeTranscript {
            apply(event, to: transcriptStore)
        }
        if plan.liveSubtitlesEnabled {
            liveCaptionStore.apply(event: event)
        }
    }

    @MainActor
    private static func apply(_ event: TranscriptionEvent, to store: TranscriptStore) {
        switch event {
        case let .preview(segment):
            store.updateUnconfirmedSegment(segment, forSource: segment.speakerLabel)
        case let .finalized(segment):
            store.finalizeSegment(segment, forSource: segment.speakerLabel)
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
