import Combine
import Foundation
import SwiftUI

/// 文字起こしセグメントの一元管理ストア。
/// @MainActor で SwiftUI と直接バインドする。
@MainActor
final class TranscriptStore: ObservableObject {
    private enum UnconfirmedMutation {
        case clear
        case upsert(TranscriptSegment)
    }

    @Published var segments: [TranscriptSegment] = []
    @Published var recordingSessions: [RecordingSessionTimeline] = []

    var recordingStartTime: Date?

    var timeBase: Date {
        recordingStartTime ?? recordingSessions.first?.startedAt ?? segments.first?.startTime ?? Date()
    }

    // MARK: - Unconfirmed Segment Throttle (per source)

    private var unconfirmedThrottleTasks: [String: Task<Void, Never>] = [:]
    private var pendingUnconfirmed: [String: UnconfirmedMutation] = [:]
    private var lastUnconfirmedUpdate: [String: ContinuousClock.Instant] = [:]
    private let throttleInterval: Duration = .milliseconds(200)

    func addSegment(_ segment: TranscriptSegment) {
        // 確定セグメントを startTime 順に挿入（複数ソース時の時系列順を保証）
        let insertIndex = segments.lastIndex(where: { $0.isConfirmed && $0.startTime <= segment.startTime })
            .map { segments.index(after: $0) }
            ?? segments.firstIndex(where: { !$0.isConfirmed })
            ?? segments.endIndex
        segments.insert(segment, at: insertIndex)
    }

    /// previewを同期的に取り除いてから確定セグメントを追加し、SwiftUI上の重複IDを防ぐ。
    func finalizeSegment(_ segment: TranscriptSegment, forSource sourceLabel: String? = nil) {
        clearUnconfirmedSegmentsImmediately(forSource: sourceLabel)
        addSegment(segment)
    }

    /// 指定ソースの未確定セグメントを更新する。
    /// 他ソースの未確定セグメントには影響しない。
    /// 200ms 以内の連続呼び出しはスロットルし、最後の状態のみ反映する。
    @discardableResult
    func updateUnconfirmedSegment(_ segment: TranscriptSegment, forSource sourceLabel: String? = nil) -> TranscriptSegment {
        let mergedSegment = mergedUnconfirmedSegment(segment, forSource: sourceLabel)
        scheduleUnconfirmedMutation(.upsert(mergedSegment), forSource: sourceLabel)
        return mergedSegment
    }

    func clearUnconfirmedSegments(forSource sourceLabel: String? = nil) {
        scheduleUnconfirmedMutation(.clear, forSource: sourceLabel)
    }

    private func clearUnconfirmedSegmentsImmediately(forSource sourceLabel: String?) {
        let key = sourceLabel ?? ""
        unconfirmedThrottleTasks[key]?.cancel()
        unconfirmedThrottleTasks[key] = nil
        pendingUnconfirmed[key] = nil
        segments.removeAll { !$0.isConfirmed && $0.speakerLabel == sourceLabel }
        lastUnconfirmedUpdate[key] = .now
    }

    private func scheduleUnconfirmedMutation(_ mutation: UnconfirmedMutation, forSource sourceLabel: String? = nil) {
        let key = sourceLabel ?? ""
        let now = ContinuousClock.now
        pendingUnconfirmed[key] = mutation

        let lastUpdate = lastUnconfirmedUpdate[key] ?? now - throttleInterval
        guard now - lastUpdate >= throttleInterval else {
            if unconfirmedThrottleTasks[key] == nil {
                unconfirmedThrottleTasks[key] = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(200))
                    guard let self, let pending = self.pendingUnconfirmed[key] else { return }
                    self.applyUnconfirmedMutation(pending, forSource: sourceLabel)
                    self.unconfirmedThrottleTasks[key] = nil
                }
            }
            return
        }

        applyUnconfirmedMutation(mutation, forSource: sourceLabel)
    }

    private func applyUnconfirmedMutation(_ mutation: UnconfirmedMutation, forSource sourceLabel: String? = nil) {
        let existingIndex = segments.lastIndex(where: { !$0.isConfirmed && $0.speakerLabel == sourceLabel })

        switch mutation {
        case .clear:
            if let index = existingIndex {
                segments.remove(at: index)
            }
        case let .upsert(segment):
            if let index = existingIndex {
                segments[index] = segment
            } else {
                segments.append(segment)
            }
        }

        let key = sourceLabel ?? ""
        lastUnconfirmedUpdate[key] = .now
        pendingUnconfirmed[key] = nil
    }

    private func mergedUnconfirmedSegment(_ segment: TranscriptSegment, forSource sourceLabel: String?) -> TranscriptSegment {
        let existingSegment = existingUnconfirmedSegment(forSource: sourceLabel)
        return TranscriptSegment(
            id: existingSegment?.id ?? segment.id,
            sessionId: segment.sessionId ?? existingSegment?.sessionId,
            startTime: segment.startTime,
            endTime: segment.endTime,
            text: segment.text,
            translatedText: segment.translatedText ?? existingSegment?.translatedText,
            isConfirmed: false,
            speakerLabel: segment.speakerLabel
        )
    }

    private func existingUnconfirmedSegment(forSource sourceLabel: String?) -> TranscriptSegment? {
        let key = sourceLabel ?? ""
        if let pendingMutation = pendingUnconfirmed[key] {
            switch pendingMutation {
            case .clear:
                return nil
            case let .upsert(segment):
                return segment
            }
        }

        return segments.last(where: { !$0.isConfirmed && $0.speakerLabel == sourceLabel })
    }

    /// DB から読み込んだセグメントを一括セットする。
    func loadSegments(_ newSegments: [TranscriptSegment]) {
        segments = newSegments
    }

    /// DB から読み込んだ録音セッションを一括セットする。
    func loadRecordingSessions(_ sessions: [RecordingSessionTimeline]) {
        recordingSessions = sessions.sorted { lhs, rhs in
            if lhs.offsetSeconds == rhs.offsetSeconds {
                return lhs.startedAt < rhs.startedAt
            }
            return lhs.offsetSeconds < rhs.offsetSeconds
        }
    }

    func upsertRecordingSession(_ session: RecordingSessionTimeline) {
        if let index = recordingSessions.firstIndex(where: { $0.id == session.id }) {
            recordingSessions[index] = session
        } else {
            recordingSessions.append(session)
        }
        loadRecordingSessions(recordingSessions)
    }

    func updateTranslatedText(for segmentID: UUID, translatedText: String?) {
        guard let index = segments.firstIndex(where: { $0.id == segmentID }) else { return }
        guard segments[index].translatedText != translatedText else { return }
        segments[index].translatedText = translatedText
    }

    func clear() {
        segments.removeAll()
        recordingSessions.removeAll()
        recordingStartTime = nil
        unconfirmedThrottleTasks.values.forEach { $0.cancel() }
        unconfirmedThrottleTasks.removeAll()
        pendingUnconfirmed.removeAll()
        lastUnconfirmedUpdate.removeAll()
    }

    func exportAsText() -> String {
        let timeBase = self.timeBase
        let sessions = recordingSessions
        return segments.map { segment in
            let time = Formatters.elapsedHHmmss(
                at: segment.startTime,
                sessionId: segment.sessionId,
                sessions: sessions,
                fallbackTimeBase: timeBase
            )
            let speaker = segment.speakerLabel.map { "[\($0)] " } ?? ""
            return "[\(time)] \(speaker)\(segment.displayText)"
        }.joined(separator: "\n")
    }

    /// LLM 要約用のテキスト。スピーカーラベルを含めない。
    func exportForSummary() -> String {
        let timeBase = self.timeBase
        let sessions = recordingSessions
        return segments.map { segment in
            let time = Formatters.elapsedHHmmss(
                at: segment.startTime,
                sessionId: segment.sessionId,
                sessions: sessions,
                fallbackTimeBase: timeBase
            )
            return "<time>\(time)</time> \(segment.displayText)"
        }.joined(separator: "\n")
    }
}
