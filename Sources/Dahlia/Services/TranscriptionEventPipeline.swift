import Foundation

/// 認識イベントを、欠落させない永続化レーンと負荷を制限した UI レーンへ分配する。
///
/// MainActor が描画で長時間占有されても、確定セグメントと翻訳の永続化は独立して進む。
/// preview は音源ごとに最新値だけを保持し、確定イベントは順序を保ってすべて UI へ渡す。
actor TranscriptionEventPipeline {
    typealias UISink = @MainActor @Sendable (TranscriptionEvent) async -> Void
    typealias PersistenceSink = @Sendable (TranscriptionEvent) async throws -> Void

    private struct PreviewKey: Hashable {
        let sessionId: UUID?
        let sourceLabel: String?
    }

    private enum UIItem {
        case event(TranscriptionEvent)
        case preview(PreviewKey)
    }

    private let uiSink: UISink
    private let persistenceSink: PersistenceSink
    private let uiSignals: AsyncStream<Void>
    private let uiSignalContinuation: AsyncStream<Void>.Continuation
    private let persistenceSignals: AsyncStream<Void>
    private let persistenceSignalContinuation: AsyncStream<Void>.Continuation

    private var uiWorker: Task<Void, Never>?
    private var persistenceWorker: Task<Void, Never>?
    private var isStarted = false
    private var isAcceptingEvents = false

    private var uiItems: [UInt64: UIItem] = [:]
    private var nextUISequence: UInt64 = 0
    private var uiDequeueSequence: UInt64 = 0
    private var latestPreviews: [PreviewKey: TranscriptionEvent] = [:]
    private var previewSequences: [PreviewKey: UInt64] = [:]
    private var isDeliveringUIEvent = false

    private var persistenceEvents: [UInt64: TranscriptionEvent] = [:]
    private var nextPersistenceSequence: UInt64 = 0
    private var persistenceDequeueSequence: UInt64 = 0
    private var isPersistingEvent = false
    private var firstPersistenceError: Error?

    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        uiSink: @escaping UISink,
        persistenceSink: @escaping PersistenceSink
    ) {
        let uiPair = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let persistencePair = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.uiSink = uiSink
        self.persistenceSink = persistenceSink
        self.uiSignals = uiPair.stream
        self.uiSignalContinuation = uiPair.continuation
        self.persistenceSignals = persistencePair.stream
        self.persistenceSignalContinuation = persistencePair.continuation
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
        }

        let persistenceSignals = persistenceSignals
        persistenceWorker = Task { [weak self] in
            for await _ in persistenceSignals {
                guard let self else { return }
                await self.drainPersistenceEvents()
            }
        }
    }

    func enqueue(_ event: TranscriptionEvent) {
        guard isAcceptingEvents else { return }

        enqueueUIEvent(event)
        uiSignalContinuation.yield()

        if event.requiresDurablePersistence {
            persistenceEvents[nextPersistenceSequence] = event
            nextPersistenceSequence &+= 1
            persistenceSignalContinuation.yield()
        }
    }

    /// 以後のイベント受付を止め、UI と永続化の両レーンを完全に drain する。
    func finish() async throws {
        guard isStarted else { return }
        isAcceptingEvents = false
        uiSignalContinuation.yield()
        persistenceSignalContinuation.yield()

        await waitUntilIdle()

        uiSignalContinuation.finish()
        persistenceSignalContinuation.finish()
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

        case .translation, .failure:
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
        while let event = nextUIEvent() {
            isDeliveringUIEvent = true
            await uiSink(event)
            isDeliveringUIEvent = false
            notifyIdleWaitersIfNeeded()
        }
        notifyIdleWaitersIfNeeded()
    }

    private func nextUIEvent() -> TranscriptionEvent? {
        while uiDequeueSequence < nextUISequence {
            let sequence = uiDequeueSequence
            uiDequeueSequence &+= 1
            guard let item = uiItems.removeValue(forKey: sequence) else { continue }

            switch item {
            case let .event(event):
                return event
            case let .preview(key):
                guard previewSequences[key] == sequence,
                      let event = latestPreviews.removeValue(forKey: key) else { continue }
                previewSequences[key] = nil
                return event
            }
        }
        return nil
    }

    private func drainPersistenceEvents() async {
        while let event = nextPersistenceEvent() {
            isPersistingEvent = true
            do {
                try await persistenceSink(event)
            } catch {
                if firstPersistenceError == nil {
                    firstPersistenceError = error
                }
            }
            isPersistingEvent = false
            notifyIdleWaitersIfNeeded()
        }
        notifyIdleWaitersIfNeeded()
    }

    private func nextPersistenceEvent() -> TranscriptionEvent? {
        guard persistenceDequeueSequence < nextPersistenceSequence else { return nil }
        let sequence = persistenceDequeueSequence
        persistenceDequeueSequence &+= 1
        return persistenceEvents.removeValue(forKey: sequence)
    }

    private func waitUntilIdle() async {
        guard !isIdle else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    private var isIdle: Bool {
        uiDequeueSequence == nextUISequence
            && persistenceDequeueSequence == nextPersistenceSequence
            && !isDeliveringUIEvent
            && !isPersistingEvent
    }

    private func notifyIdleWaitersIfNeeded() {
        guard isIdle, !idleWaiters.isEmpty else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private extension TranscriptionEvent {
    var requiresDurablePersistence: Bool {
        switch self {
        case .finalized, .translation:
            true
        case .preview, .clearPreview, .failure:
            false
        }
    }
}
