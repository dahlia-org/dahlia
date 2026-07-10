import Combine
import Foundation

/// 現在の録音セッションに限った、一時的なライブ字幕の表示状態。
@MainActor
final class LiveCaptionStore: ObservableObject {
    private static let maximumRetainedSegmentCount = 20

    @Published private(set) var segments: [TranscriptSegment] = []
    @Published private(set) var activeSessionId: UUID?
    @Published private(set) var failureMessage: String?

    /// 新しいセッションを開始する。同じセッションへの再設定は現在の字幕を維持する。
    func start(sessionId: UUID) {
        guard activeSessionId != sessionId else { return }

        segments.removeAll()
        failureMessage = nil
        activeSessionId = sessionId
    }

    func apply(event: TranscriptionEvent) {
        switch event {
        case let .preview(segment):
            guard accepts(segment) else { return }
            upsertPreview(segment)
        case let .finalized(segment):
            guard accepts(segment) else { return }
            appendFinalized(segment)
        case let .clearPreview(sessionId, sourceLabel):
            guard activeSessionId == sessionId else { return }
            clearPreview(forSource: sourceLabel)
        case let .translation(sessionId, segmentID, translatedText):
            guard activeSessionId == sessionId,
                  let index = segments.firstIndex(where: { $0.id == segmentID }) else { return }
            segments[index].translatedText = translatedText
        case let .failure(sessionId, _, _, message):
            guard activeSessionId == sessionId else { return }
            failureMessage = message
        }
    }

    /// 正本文字起こしの現在セッション分を、字幕を有効化した時点の初期値として取り込む。
    func seed(_ newSegments: [TranscriptSegment], sessionId: UUID) {
        guard activeSessionId == sessionId else { return }
        segments = Array(
            newSegments
                .lazy
                .filter { $0.sessionId == sessionId }
                .suffix(Self.maximumRetainedSegmentCount)
        )
    }

    func clear() {
        segments.removeAll()
        activeSessionId = nil
        failureMessage = nil
    }

    private func accepts(_ segment: TranscriptSegment) -> Bool {
        guard let activeSessionId else { return false }
        return segment.sessionId == activeSessionId
    }

    private func upsertPreview(_ newSegment: TranscriptSegment) {
        var preview = newSegment
        preview.isConfirmed = false

        if preview.translatedText == nil,
           let existingPreview = segments.last(where: {
               !$0.isConfirmed && $0.speakerLabel == preview.speakerLabel
           }),
           existingPreview.id == preview.id {
            preview.translatedText = existingPreview.translatedText
        }

        clearPreview(forSource: preview.speakerLabel)
        segments.append(preview)
    }

    private func appendFinalized(_ newSegment: TranscriptSegment) {
        var finalized = newSegment
        finalized.isConfirmed = true

        if finalized.translatedText == nil,
           let existingSegment = segments.first(where: { $0.id == finalized.id }) {
            finalized.translatedText = existingSegment.translatedText
        }

        segments.removeAll {
            $0.id == finalized.id || (!$0.isConfirmed && $0.speakerLabel == finalized.speakerLabel)
        }

        // LiveSubtitleOverlayPayload は未確定セグメントを末尾として扱うため、
        // 確定セグメントは残っている preview より前へ追加する。
        let insertionIndex = segments.firstIndex(where: { !$0.isConfirmed }) ?? segments.endIndex
        segments.insert(finalized, at: insertionIndex)
        trimOldSegmentsIfNeeded()
    }

    private func clearPreview(forSource sourceLabel: String?) {
        segments.removeAll {
            !$0.isConfirmed && $0.speakerLabel == sourceLabel
        }
    }

    private func trimOldSegmentsIfNeeded() {
        guard segments.count > Self.maximumRetainedSegmentCount else { return }
        segments.removeFirst(segments.count - Self.maximumRetainedSegmentCount)
    }
}
