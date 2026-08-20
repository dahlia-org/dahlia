import Combine
import Foundation

/// 現在の録音セッションに限った、一時的なライブ字幕の表示状態。
@MainActor
final class LiveCaptionStore: ObservableObject {
    enum OverlayChange {
        case reload
        case preview(TranscriptSegment)
        case finalized(TranscriptSegment)
        case clearPreview(sourceLabel: String?)
        case update(TranscriptSegment)
    }

    @Published private(set) var segments: [TranscriptSegment] = []
    @Published private(set) var activeSessionId: UUID?
    @Published private(set) var failureMessage: String?
    let overlayChanges = PassthroughSubject<OverlayChange, Never>()
    private var segmentIndices: [UUID: Int] = [:]

    /// 新しいセッションを開始する。同じセッションへの再設定は現在の字幕を維持する。
    func start(sessionId: UUID) {
        guard activeSessionId != sessionId else { return }

        segments.removeAll()
        segmentIndices.removeAll()
        failureMessage = nil
        activeSessionId = sessionId
        overlayChanges.send(.reload)
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
                  let index = segmentIndices[segmentID] else { return }
            segments[index].translatedText = translatedText
            overlayChanges.send(.update(segments[index]))
        case let .failure(sessionId, _, _, message):
            guard activeSessionId == sessionId else { return }
            failureMessage = message
        }
    }

    /// 正本文字起こしの現在セッション分を、字幕を有効化した時点の初期値として取り込む。
    func seed(_ newSegments: [TranscriptSegment], sessionId: UUID) {
        guard activeSessionId == sessionId else { return }
        let incomingSegments = newSegments.filter { $0.sessionId == sessionId }
        guard !segments.isEmpty else {
            segments = incomingSegments
            rebuildSegmentIndices()
            overlayChanges.send(.reload)
            return
        }

        var mergedSegments = segments.filter(\.isConfirmed)
        var confirmedIndices = Dictionary(uniqueKeysWithValues: mergedSegments.enumerated().map { ($1.id, $0) })
        for segment in incomingSegments where segment.isConfirmed {
            if let index = confirmedIndices[segment.id] {
                mergedSegments[index] = segment
            } else {
                confirmedIndices[segment.id] = mergedSegments.endIndex
                mergedSegments.append(segment)
            }
        }
        mergedSegments.append(contentsOf: incomingSegments.filter { !$0.isConfirmed })
        segments = mergedSegments
        rebuildSegmentIndices()
        overlayChanges.send(.reload)
    }

    func clear() {
        segments.removeAll()
        segmentIndices.removeAll()
        activeSessionId = nil
        failureMessage = nil
        overlayChanges.send(.reload)
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
            replaceSegments(from: existingPreviewIndex, with: replacement)
        } else {
            segmentIndices[preview.id] = segments.endIndex
            segments.append(preview)
        }
        overlayChanges.send(.preview(preview))
    }

    private func appendFinalized(_ newSegment: TranscriptSegment) {
        var finalized = newSegment
        finalized.isConfirmed = true

        let existingSegmentIndex = segmentIndices[finalized.id]
        if let existingSegmentIndex, finalized.translatedText == nil {
            finalized.translatedText = segments[existingSegmentIndex].translatedText
        }

        let confirmedInsertionIndex = segments.lastIndex(where: \.isConfirmed).map { $0 + 1 } ?? segments.startIndex
        let replacementStart = min(existingSegmentIndex ?? confirmedInsertionIndex, confirmedInsertionIndex)
        var replacement = Array(segments[replacementStart...])
        replacement.removeAll {
            $0.id == finalized.id || (!$0.isConfirmed && $0.speakerLabel == finalized.speakerLabel)
        }
        let insertionIndex = replacement.lastIndex(where: \.isConfirmed).map { $0 + 1 } ?? replacement.startIndex
        replacement.insert(finalized, at: insertionIndex)
        replaceSegments(from: replacementStart, with: replacement)
        overlayChanges.send(.finalized(finalized))
    }

    private func clearPreview(forSource sourceLabel: String?) {
        guard let index = previewIndex(forSource: sourceLabel) else { return }
        segmentIndices.removeValue(forKey: segments[index].id)
        segments.remove(at: index)
        refreshSegmentIndices(from: index)
        overlayChanges.send(.clearPreview(sourceLabel: sourceLabel))
    }

    private func previewIndex(forSource sourceLabel: String?) -> Int? {
        let previewStartIndex = segments.lastIndex(where: \.isConfirmed).map { $0 + 1 } ?? segments.startIndex
        return segments[previewStartIndex...].lastIndex {
            !$0.isConfirmed && $0.speakerLabel == sourceLabel
        }
    }

    private func replaceSegments(from startIndex: Int, with replacement: [TranscriptSegment]) {
        for segment in segments[startIndex...] {
            segmentIndices.removeValue(forKey: segment.id)
        }
        segments.replaceSubrange(startIndex..., with: replacement)
        refreshSegmentIndices(from: startIndex)
    }

    private func rebuildSegmentIndices() {
        segmentIndices = Dictionary(uniqueKeysWithValues: segments.enumerated().map { ($1.id, $0) })
    }

    private func refreshSegmentIndices(from startIndex: Int) {
        for index in startIndex ..< segments.endIndex {
            segmentIndices[segments[index].id] = index
        }
    }
}
