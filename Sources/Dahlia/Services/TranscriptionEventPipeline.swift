import Foundation

/// 認識イベントを、欠落させない永続化レーンと負荷を制限した UI レーンへ分配する。
///
/// MainActor が描画で長時間占有されても、確定セグメントと翻訳の永続化は独立して進む。
/// preview は音源ごとに最新値だけを保持し、確定イベントは順序を保ってすべて UI へ渡す。
actor TranscriptionEventPipeline {
    typealias UISink = @MainActor @Sendable ([TranscriptionEvent]) async -> Void
    typealias PersistenceSink = @Sendable ([TranscriptionEvent]) async throws -> Void
    typealias PersistenceResetSink = @Sendable () async -> Void

    private struct PreviewKey: Hashable {
        let sessionId: UUID?
        let sourceLabel: String?
    }

    private enum UIItem {
        case event(TranscriptionEvent)
        case preview(PreviewKey)
        case barrier(CheckedContinuation<Void, Never>)
    }

    private struct UIDelivery {
        let events: [TranscriptionEvent]
        let barrier: CheckedContinuation<Void, Never>?
    }

    private enum PersistenceItem {
        case event(TranscriptionEvent)
        case reset(CheckedContinuation<Void, Never>)
    }

    private let uiSink: UISink
    private let persistenceSink: PersistenceSink
    private let persistenceResetSink: PersistenceResetSink
    private let uiSignals: AsyncStream<Void>
    private let uiSignalContinuation: AsyncStream<Void>.Continuation
    private let persistenceItems: AsyncStream<PersistenceItem>
    private let persistenceContinuation: AsyncStream<PersistenceItem>.Continuation

    private var uiWorker: Task<Void, Never>?
    private var persistenceWorker: Task<Void, Never>?
    private var isStarted = false
    private var isAcceptingEvents = false

    private var uiItems: [UInt64: UIItem] = [:]
    private var nextUISequence: UInt64 = 0
    private var uiDequeueSequence: UInt64 = 0
    private var latestPreviews: [PreviewKey: TranscriptionEvent] = [:]
    private var previewSequences: [PreviewKey: UInt64] = [:]

    private var pendingPersistenceEvents: [TranscriptionEvent] = []
    private var persistenceBatchTask: Task<Void, Never>?
    private var firstPersistenceError: Error?

    init(
        uiSink: @escaping UISink,
        persistenceSink: @escaping PersistenceSink,
        persistenceResetSink: @escaping PersistenceResetSink = {}
    ) {
        let uiPair = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let persistencePair = AsyncStream.makeStream(
            of: PersistenceItem.self,
            bufferingPolicy: .unbounded
        )
        self.uiSink = uiSink
        self.persistenceSink = persistenceSink
        self.persistenceResetSink = persistenceResetSink
        self.uiSignals = uiPair.stream
        self.uiSignalContinuation = uiPair.continuation
        self.persistenceItems = persistencePair.stream
        self.persistenceContinuation = persistencePair.continuation
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        isAcceptingEvents = true

        let uiSignals = uiSignals
        uiWorker = Task { [weak self] in
            for await _ in uiSignals {
                guard let self else { return }
                await self.drainUIEvents()
            }
            await self?.drainUIEvents()
        }

        let persistenceItems = persistenceItems
        persistenceWorker = Task { [weak self] in
            for await item in persistenceItems {
                guard let self else { return }
                await self.consumePersistenceItem(item)
            }
            await self?.finishPersistenceBatches()
        }
    }

    func enqueue(_ event: TranscriptionEvent) {
        guard isAcceptingEvents else { return }

        enqueueUIEvent(event)
        uiSignalContinuation.yield()

        if event.requiresDurablePersistence {
            persistenceContinuation.yield(.event(event))
        }
    }

    /// この呼び出しより前の永続化イベントを保存してから、writer の追跡状態を直列にリセットする。
    func resetPersistence() async {
        guard isAcceptingEvents else { return }
        await withCheckedContinuation { continuation in
            persistenceContinuation.yield(.reset(continuation))
        }
    }

    /// この呼び出しより前に enqueue された UI イベントが MainActor へ反映されるまで待つ。
    func flushUI() async {
        guard isAcceptingEvents else { return }
        await withCheckedContinuation { continuation in
            appendUIItem(.barrier(continuation))
            uiSignalContinuation.yield()
        }
    }

    /// 以後のイベント受付を止め、両ストリームの worker が最後まで drain するのを待つ。
    func finish() async throws {
        guard isStarted else { return }
        isAcceptingEvents = false
        uiSignalContinuation.finish()
        persistenceContinuation.finish()

        let uiWorker = uiWorker
        let persistenceWorker = persistenceWorker
        self.uiWorker = nil
        self.persistenceWorker = nil
        await uiWorker?.value
        await persistenceWorker?.value
        isStarted = false

        if let firstPersistenceError {
            throw firstPersistenceError
        }
    }

    private func enqueueUIEvent(_ event: TranscriptionEvent) {
        switch event {
        case let .preview(segment):
            let key = PreviewKey(sessionId: segment.sessionId, sourceLabel: segment.speakerLabel)
            latestPreviews[key] = event
            guard previewSequences[key] == nil else { return }
            let sequence = appendUIItem(.preview(key))
            previewSequences[key] = sequence

        case let .finalized(segment):
            discardPendingPreview(sessionId: segment.sessionId, sourceLabel: segment.speakerLabel)
            appendUIItem(.event(event))

        case let .clearPreview(sessionId, sourceLabel):
            discardPendingPreview(sessionId: sessionId, sourceLabel: sourceLabel)
            appendUIItem(.event(event))

        case .previewTranslation, .translation, .failure:
            appendUIItem(.event(event))
        }
    }

    @discardableResult
    private func appendUIItem(_ item: UIItem) -> UInt64 {
        let sequence = nextUISequence
        uiItems[sequence] = item
        nextUISequence &+= 1
        return sequence
    }

    private func discardPendingPreview(sessionId: UUID?, sourceLabel: String?) {
        let key = PreviewKey(sessionId: sessionId, sourceLabel: sourceLabel)
        latestPreviews[key] = nil
        previewSequences[key] = nil
    }

    private func drainUIEvents() async {
        while let delivery = nextUIDelivery() {
            if !delivery.events.isEmpty {
                await uiSink(delivery.events)
            }
            delivery.barrier?.resume()
        }
    }

    private func nextUIDelivery() -> UIDelivery? {
        var events: [TranscriptionEvent] = []

        while uiDequeueSequence < nextUISequence {
            let sequence = uiDequeueSequence
            uiDequeueSequence &+= 1
            guard let item = uiItems.removeValue(forKey: sequence) else { continue }

            switch item {
            case let .event(event):
                events.append(event)
            case let .preview(key):
                guard previewSequences[key] == sequence,
                      let event = latestPreviews.removeValue(forKey: key) else { continue }
                previewSequences[key] = nil
                events.append(event)
            case let .barrier(continuation):
                return UIDelivery(events: events, barrier: continuation)
            }
        }

        return events.isEmpty ? nil : UIDelivery(events: events, barrier: nil)
    }

    private func enqueuePersistenceBatch(_ event: TranscriptionEvent) {
        pendingPersistenceEvents.append(event)
        schedulePersistenceBatchIfNeeded()
    }

    private func consumePersistenceItem(_ item: PersistenceItem) async {
        switch item {
        case let .event(event):
            enqueuePersistenceBatch(event)
        case let .reset(continuation):
            await finishPersistenceBatches()
            await persistenceResetSink()
            continuation.resume()
        }
    }

    private func schedulePersistenceBatchIfNeeded() {
        guard persistenceBatchTask == nil else { return }
        persistenceBatchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            await self?.flushPersistenceBatch()
        }
    }

    private func flushPersistenceBatch() async {
        guard !pendingPersistenceEvents.isEmpty else {
            persistenceBatchTask = nil
            return
        }

        let events = pendingPersistenceEvents
        pendingPersistenceEvents.removeAll(keepingCapacity: true)
        do {
            try await persistenceSink(events)
        } catch {
            if firstPersistenceError == nil {
                firstPersistenceError = error
            }
        }

        persistenceBatchTask = nil
        if !pendingPersistenceEvents.isEmpty {
            schedulePersistenceBatchIfNeeded()
        }
    }

    private func finishPersistenceBatches() async {
        while let task = persistenceBatchTask {
            task.cancel()
            await task.value
        }
        if !pendingPersistenceEvents.isEmpty {
            await flushPersistenceBatch()
        }
    }
}

private extension TranscriptionEvent {
    var requiresDurablePersistence: Bool {
        switch self {
        case .finalized, .translation:
            true
        case .preview, .clearPreview, .previewTranslation, .failure:
            false
        }
    }
}
