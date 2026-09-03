import Foundation

/// 認識経路を MainActor から切り離し、再生成可能なライブ字幕イベントを有界に配送する。
actor LiveCaptionEventRelay {
    typealias Sink = @MainActor @Sendable ([TranscriptionEvent]) async -> Void

    static let maximumPendingEventCount = 100

    private let sink: Sink
    private var pendingEvents: [TranscriptionEvent] = []
    private var worker: Task<Void, Never>?

    init(sink: @escaping Sink) {
        self.sink = sink
    }

    func enqueue(_ event: TranscriptionEvent) {
        compactPendingEvents(for: event)
        pendingEvents.append(event)
        trimPendingEventsIfNeeded()
        startWorkerIfNeeded()
    }

    func finish() async {
        await worker?.value
    }

    func cancel() {
        pendingEvents.removeAll()
        worker?.cancel()
        worker = nil
    }

    func pendingEventCount() -> Int {
        pendingEvents.count
    }

    private func compactPendingEvents(for event: TranscriptionEvent) {
        switch event {
        case let .preview(segment):
            removePendingPreviews(sessionId: segment.sessionId, sourceLabel: segment.audioSource)
        case let .finalized(segment):
            removePendingPreviews(sessionId: segment.sessionId, sourceLabel: segment.audioSource)
            pendingEvents.removeAll {
                guard case let .finalized(pendingSegment) = $0 else { return false }
                return pendingSegment.id == segment.id
            }
        case let .clearPreview(sessionId, sourceLabel):
            removePendingPreviews(sessionId: sessionId, sourceLabel: sourceLabel)
            pendingEvents.removeAll {
                guard case let .clearPreview(pendingSessionId, pendingSourceLabel) = $0 else { return false }
                return pendingSessionId == sessionId && pendingSourceLabel == sourceLabel
            }
        case let .previewTranslation(sessionId, segmentID, _),
             let .translation(sessionId, segmentID, _):
            pendingEvents.removeAll {
                switch $0 {
                case let .previewTranslation(pendingSessionId, pendingSegmentID, _),
                     let .translation(pendingSessionId, pendingSegmentID, _):
                    pendingSessionId == sessionId && pendingSegmentID == segmentID
                default:
                    false
                }
            }
        case let .failure(sessionId, _, sourceLabel, _):
            pendingEvents.removeAll {
                guard case let .failure(pendingSessionId, _, pendingSourceLabel, _) = $0 else { return false }
                return pendingSessionId == sessionId && pendingSourceLabel == sourceLabel
            }
        }
    }

    private func removePendingPreviews(sessionId: UUID?, sourceLabel: String?) {
        pendingEvents.removeAll {
            guard case let .preview(segment) = $0 else { return false }
            return segment.sessionId == sessionId && segment.audioSource == sourceLabel
        }
    }

    private func trimPendingEventsIfNeeded() {
        guard pendingEvents.count > Self.maximumPendingEventCount else { return }
        while pendingEvents.count > Self.maximumPendingEventCount {
            let removalIndex = pendingEvents.firstIndex {
                guard case .clearPreview = $0 else { return true }
                return false
            } ?? pendingEvents.startIndex
            pendingEvents.remove(at: removalIndex)
        }
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while !Task.isCancelled, !pendingEvents.isEmpty {
            let events = pendingEvents
            pendingEvents.removeAll(keepingCapacity: true)
            await sink(events)
        }
        worker = nil
    }
}
