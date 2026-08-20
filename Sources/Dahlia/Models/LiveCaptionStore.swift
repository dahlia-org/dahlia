import Combine
import Foundation

/// 現在の録音セッションに限った、一時的なライブ字幕の表示状態。
@MainActor
final class LiveCaptionStore: ObservableObject {
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
        case let .previewTranslation(sessionId, segmentID, translatedText),
             let .translation(sessionId, segmentID, translatedText):
            guard activeSessionId == sessionId,
                  let index = segments.lastIndex(where: { $0.id == segmentID }) else { return }
            segments[index].translatedText = translatedText
        case let .failure(sessionId, _, _, message):
            guard activeSessionId == sessionId else { return }
            failureMessage = message
        }
    }

    /// 正本文字起こしの現在セッション分を、字幕を有効化した時点の初期値として取り込む。
    func seed(_ newSegments: [TranscriptSegment], sessionId: UUID) {
        guard activeSessionId == sessionId else { return }
        segments = newSegments.filter { $0.sessionId == sessionId }
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

        if let existingPreviewIndex = previewIndex(forSource: preview.speakerLabel) {
            let existingPreview = segments[existingPreviewIndex]
            if preview.translatedText == nil, existingPreview.id == preview.id {
                preview.translatedText = existingPreview.translatedText
            }
            var replacement = Array(segments[segments.index(after: existingPreviewIndex)...])
            replacement.append(preview)
            segments.replaceSubrange(existingPreviewIndex..., with: replacement)
        } else {
            segments.append(preview)
        }
    }

    private func appendFinalized(_ newSegment: TranscriptSegment) {
        var finalized = newSegment
        finalized.isConfirmed = true

        let existingSegmentIndex = segments.lastIndex(where: { $0.id == finalized.id })
        if let existingSegmentIndex {
            if finalized.translatedText == nil {
                finalized.translatedText = segments[existingSegmentIndex].translatedText
            }
        }

        let confirmedInsertionIndex = segments.lastIndex(where: \.isConfirmed).map { $0 + 1 } ?? segments.startIndex
        let replacementStart = min(existingSegmentIndex ?? confirmedInsertionIndex, confirmedInsertionIndex)
        var replacement = Array(segments[replacementStart...])
        replacement.removeAll {
            $0.id == finalized.id || (!$0.isConfirmed && $0.speakerLabel == finalized.speakerLabel)
        }
        let insertionIndex = replacement.lastIndex(where: \.isConfirmed).map { $0 + 1 } ?? replacement.startIndex
        replacement.insert(finalized, at: insertionIndex)
        segments.replaceSubrange(replacementStart..., with: replacement)
    }

    private func clearPreview(forSource sourceLabel: String?) {
        guard let index = previewIndex(forSource: sourceLabel) else { return }
        segments.remove(at: index)
    }

    private func previewIndex(forSource sourceLabel: String?) -> Int? {
        segments.lastIndex {
            !$0.isConfirmed && $0.speakerLabel == sourceLabel
        }
    }
}
