import Foundation

// swiftlint:disable file_length
/// 認識イベントを、欠落させない永続化レーンと負荷を制限した UI レーンへ分配する。
///
/// MainActor が描画で長時間占有されても、確定セグメントと翻訳の永続化は独立して進む。
/// preview は音源ごとに最新値だけを保持する。UI backlog は上限超過時に DB 再読込へ集約する。
actor TranscriptionEventPipeline { // swiftlint:disable:this type_body_length
    typealias UISink = @MainActor @Sendable ([TranscriptionEvent]) async -> Void
    typealias EventObserver = @Sendable (TranscriptionEvent) async -> Void
    typealias UIReloadSink = @MainActor @Sendable () async -> Void
    typealias PersistenceSink = @Sendable ([TranscriptionEvent]) async throws -> Void
    typealias PersistenceFlushSink = @Sendable () async throws -> Void
    typealias PersistenceResetSink = @Sendable () async throws -> Void
    typealias PersistenceBatchSleep = @Sendable () async throws -> Void

    static let maximumPendingUIEventCount = 300
    static let maximumUIFinishWait: Duration = .seconds(2)
    private static let maximumRetainedUIControlEventCount = 50
    private static let maximumUIOperationWait: Duration = .seconds(30)

    private struct PreviewKey: Hashable {
        let sessionId: UUID?
        let sourceLabel: String?
    }

    private enum UIControlKey: Hashable {
        case previewState(sessionId: UUID?, sourceLabel: String?)
        case previewTranslation(sessionId: UUID, segmentID: UUID)
        case failure(sessionId: UUID, sourceLabel: String?)
    }

    private enum UIItem {
        case reloadableEvent(TranscriptionEvent)
        case control(UIControlKey)
        case preview(PreviewKey)
        case reloadRequired
        case barrier(UUID)
    }

    private struct UIDelivery {
        let events: [TranscriptionEvent]
        let requiresReload: Bool
        let barrierID: UUID?
    }

    private enum PersistenceItem {
        case event(TranscriptionEvent)
        case flush(CheckedContinuation<Result<Void, Error>, Never>)
        case reset(CheckedContinuation<Result<Void, Error>, Never>)
        case scheduledFlush(UInt64)
    }

    private let uiSink: UISink
    private let eventObserver: EventObserver?
    private let uiReloadSink: UIReloadSink
    private let persistenceSink: PersistenceSink
    private let persistenceFlushSink: PersistenceFlushSink
    private let persistenceResetSink: PersistenceResetSink
    private let persistenceBatchSleep: PersistenceBatchSleep
    private let uiSignals: AsyncStream<Void>
    private let uiSignalContinuation: AsyncStream<Void>.Continuation
    private let persistenceItems: AsyncStream<PersistenceItem>
    private let persistenceContinuation: AsyncStream<PersistenceItem>.Continuation

    private var uiWorker: Task<Void, Never>?
    private var persistenceWorker: Task<Void, Never>?
    private var isStarted = false
    private var isAcceptingEvents = false
    private var isPersistenceStreamOpen = false

    private var uiItems: [UInt64: UIItem] = [:]
    private var nextUISequence: UInt64 = 0
    private var uiDequeueSequence: UInt64 = 0
    private var latestPreviews: [PreviewKey: TranscriptionEvent] = [:]
    private var previewSequences: [PreviewKey: UInt64] = [:]
    private var latestControls: [UIControlKey: TranscriptionEvent] = [:]
    private var controlSequences: [UIControlKey: UInt64] = [:]
    private var uiBarriers: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var pendingUIEventCount = 0
    private var isUILaneSuspended = false

    private var needsDeferredUIReload = false
    private var uiReloadRetryTask: Task<Void, Never>?
    private var uiReloadRetryGeneration: UInt64 = 0
    private var uiReloadRetryDelay: Duration = .milliseconds(250)

    private var pendingPersistenceEvents: [TranscriptionEvent] = []
    private var persistenceBatchTask: Task<Void, Never>?
    private var persistenceBatchGeneration: UInt64 = 0
    private var firstPersistenceError: Error?

    init(
        uiSink: @escaping UISink,
        eventObserver: EventObserver? = nil,
        uiReloadSink: @escaping UIReloadSink = {},
        persistenceSink: @escaping PersistenceSink,
        persistenceFlushSink: @escaping PersistenceFlushSink = {},
        persistenceResetSink: @escaping PersistenceResetSink = {},
        persistenceBatchSleep: @escaping PersistenceBatchSleep = {
            try await Task.sleep(for: .milliseconds(50))
        }
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
        self.eventObserver = eventObserver
        self.uiReloadSink = uiReloadSink
        self.persistenceSink = persistenceSink
        self.persistenceFlushSink = persistenceFlushSink
        self.persistenceResetSink = persistenceResetSink
        self.persistenceBatchSleep = persistenceBatchSleep
        self.uiSignals = uiPair.stream
        self.uiSignalContinuation = uiPair.continuation
        self.persistenceItems = persistencePair.stream
        self.persistenceContinuation = persistencePair.continuation
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        isAcceptingEvents = true
        isPersistenceStreamOpen = true

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

    func enqueue(_ event: TranscriptionEvent) async {
        guard isAcceptingEvents else { return }

        // Observers that require every event must run before the bounded UI projection
        // compacts finalized events into a reload marker.
        await eventObserver?(event)
        enqueueUIEvent(event)
        uiSignalContinuation.yield()

        if event.requiresDurablePersistence {
            persistenceContinuation.yield(.event(event))
        }
    }

    /// この呼び出しより前の永続化イベントを保存してから、writer の追跡状態を直列にリセットする。
    func resetPersistence() async throws {
        guard isAcceptingEvents else { return }
        let result = await withCheckedContinuation { continuation in
            persistenceContinuation.yield(.reset(continuation))
        }
        try result.get()
    }

    /// この呼び出しより前に enqueue された UI イベントが MainActor へ反映されるまで待つ。
    func flushUI() async {
        guard isAcceptingEvents else { return }
        await withCheckedContinuation { continuation in
            let barrierID = UUID.v7()
            uiBarriers[barrierID] = continuation
            appendUIItem(.barrier(barrierID))
            uiSignalContinuation.yield()
        }
    }

    /// 以後のイベント受付を止め、両ストリームの worker が最後まで drain するのを待つ。
    func finish() async throws {
        guard isStarted else { return }
        isAcceptingEvents = false
        uiSignalContinuation.finish()

        let uiWorker = uiWorker
        let persistenceWorker = persistenceWorker
        self.uiWorker = nil
        self.persistenceWorker = nil
        let didFinishUI = await waitForUIWorker(uiWorker)
        if !didFinishUI {
            uiWorker?.cancel()
        }
        if !didFinishUI || isUILaneSuspended || uiDequeueSequence < nextUISequence {
            needsDeferredUIReload = true
        }
        resumeAllUIBarriers()

        cancelDeferredUIReloadRetry()
        isPersistenceStreamOpen = false
        persistenceContinuation.finish()
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
            compactUIProjectionIfNeeded()
            latestPreviews[key] = event
            guard previewSequences[key] == nil else { return }
            pendingUIEventCount += 1
            let sequence = appendUIItem(.preview(key))
            previewSequences[key] = sequence

        case let .finalized(segment):
            discardPendingPreview(sessionId: segment.sessionId, sourceLabel: segment.speakerLabel)
            if segment.isConfirmed {
                appendReloadableUIItem(.reloadableEvent(event))
            } else {
                appendControlUIEvent(event)
            }

        case let .clearPreview(sessionId, sourceLabel):
            discardPendingPreview(sessionId: sessionId, sourceLabel: sourceLabel)
            appendControlUIEvent(event)

        case .translation:
            appendReloadableUIItem(.reloadableEvent(event))

        case .previewTranslation, .failure:
            appendControlUIEvent(event)
        }
    }

    private func appendControlUIEvent(_ event: TranscriptionEvent) {
        compactUIProjectionIfNeeded()
        let key = uiControlKey(for: event)
        latestControls[key] = event
        guard controlSequences[key] == nil else { return }
        pendingUIEventCount += 1
        controlSequences[key] = appendUIItem(.control(key))
    }

    @discardableResult
    private func appendReloadableUIItem(_ item: UIItem) -> UInt64 {
        compactUIProjectionIfNeeded()
        pendingUIEventCount += 1
        return appendUIItem(item)
    }

    private func compactUIProjectionIfNeeded() {
        if pendingUIEventCount >= Self.maximumPendingUIEventCount {
            compactUIProjectionForReload()
        }
    }

    @discardableResult
    private func appendUIItem(_ item: UIItem) -> UInt64 {
        let sequence = nextUISequence
        uiItems[sequence] = item
        nextUISequence &+= 1
        return sequence
    }

    private func compactUIProjectionForReload() {
        let retainedControlSequences = retainedUIControlSequences()
        var compactedItems: [UIItem] = []
        var insertedReload = false
        for sequence in uiDequeueSequence ..< nextUISequence {
            guard let item = compactedUIItem(
                at: sequence,
                retainingControlsAt: retainedControlSequences
            ) else { continue }
            if case .reloadRequired = item {
                guard !insertedReload else { continue }
                insertedReload = true
            }
            compactedItems.append(item)
        }

        latestPreviews.removeAll()
        previewSequences.removeAll()
        let retainedControlKeys = Set(compactedItems.compactMap { item -> UIControlKey? in
            if case let .control(key) = item { return key }
            return nil
        })
        latestControls = latestControls.filter { retainedControlKeys.contains($0.key) }
        controlSequences.removeAll(keepingCapacity: true)
        uiItems.removeAll(keepingCapacity: true)
        uiDequeueSequence = 0
        nextUISequence = 0
        for item in compactedItems {
            let sequence = appendUIItem(item)
            if case let .control(key) = item {
                controlSequences[key] = sequence
            }
        }
        pendingUIEventCount = compactedItems.reduce(into: 0) { count, item in
            if case .barrier = item { return }
            count += 1
        }
    }

    private func compactedUIItem(
        at sequence: UInt64,
        retainingControlsAt retainedControlSequences: Set<UInt64>
    ) -> UIItem? {
        guard let item = uiItems[sequence] else { return nil }
        return switch item {
        case .reloadableEvent, .preview, .reloadRequired:
            .reloadRequired
        case .control where retainedControlSequences.contains(sequence), .barrier:
            item
        case .control:
            .reloadRequired
        }
    }

    private func retainedUIControlSequences() -> Set<UInt64> {
        var retained: Set<UInt64> = []
        var keys: Set<UIControlKey> = []
        guard nextUISequence > uiDequeueSequence else { return retained }

        for sequence in stride(from: nextUISequence - 1, through: uiDequeueSequence, by: -1) {
            guard retained.count < Self.maximumRetainedUIControlEventCount,
                  case let .control(key) = uiItems[sequence],
                  keys.insert(key).inserted
            else { continue }
            retained.insert(sequence)
        }
        return retained
    }

    private func uiControlKey(for event: TranscriptionEvent) -> UIControlKey {
        switch event {
        case let .finalized(segment):
            .previewState(sessionId: segment.sessionId, sourceLabel: segment.speakerLabel)
        case let .clearPreview(sessionId, sourceLabel):
            .previewState(sessionId: sessionId, sourceLabel: sourceLabel)
        case let .previewTranslation(sessionId, segmentID, _):
            .previewTranslation(sessionId: sessionId, segmentID: segmentID)
        case let .failure(sessionId, _, sourceLabel, _):
            .failure(sessionId: sessionId, sourceLabel: sourceLabel)
        case .preview, .translation:
            preconditionFailure("Only UI control events have a control key")
        }
    }

    private func discardPendingPreview(sessionId: UUID?, sourceLabel: String?) {
        let key = PreviewKey(sessionId: sessionId, sourceLabel: sourceLabel)
        latestPreviews[key] = nil
        previewSequences[key] = nil
    }

    private func drainUIEvents() async {
        guard !isUILaneSuspended else { return }
        while !Task.isCancelled, let delivery = nextUIDelivery() {
            var shouldReload = false
            if delivery.requiresReload {
                let persistenceResult = await flushPersistenceThroughCurrentPosition()
                guard !Task.isCancelled else {
                    resumeUIBarrier(delivery.barrierID)
                    return
                }
                if case .success = persistenceResult {
                    clearDeferredUIReloadState()
                    shouldReload = true
                } else {
                    deferUIReloadUntilPersistenceRecovers()
                }
            }
            guard shouldReload || !delivery.events.isEmpty else {
                resumeUIBarrier(delivery.barrierID)
                continue
            }

            let reloadSink = uiReloadSink
            let eventSink = uiSink
            let events = delivery.events
            let performsReload = shouldReload
            let didComplete = await runBoundedUIOperation(barrierID: delivery.barrierID) {
                if performsReload {
                    await reloadSink()
                }
                if !events.isEmpty {
                    await eventSink(events)
                }
            }
            guard didComplete, !Task.isCancelled else {
                isUILaneSuspended = true
                return
            }
        }
    }

    private func nextUIDelivery() -> UIDelivery? {
        var events: [TranscriptionEvent] = []
        var requiresReload = false

        while uiDequeueSequence < nextUISequence {
            let sequence = uiDequeueSequence
            uiDequeueSequence &+= 1
            guard let item = uiItems.removeValue(forKey: sequence) else { continue }

            switch item {
            case let .reloadableEvent(event):
                pendingUIEventCount -= 1
                events.append(event)
            case let .control(key):
                pendingUIEventCount -= 1
                guard controlSequences[key] == sequence,
                      let event = latestControls.removeValue(forKey: key)
                else { continue }
                controlSequences[key] = nil
                events.append(event)
            case let .preview(key):
                pendingUIEventCount -= 1
                guard previewSequences[key] == sequence,
                      let event = latestPreviews.removeValue(forKey: key) else { continue }
                previewSequences[key] = nil
                events.append(event)
            case .reloadRequired:
                pendingUIEventCount -= 1
                requiresReload = true
            case let .barrier(continuation):
                return UIDelivery(events: events, requiresReload: requiresReload, barrierID: continuation)
            }
        }

        return events.isEmpty && !requiresReload
            ? nil
            : UIDelivery(events: events, requiresReload: requiresReload, barrierID: nil)
    }

    private func enqueuePersistenceBatch(_ event: TranscriptionEvent) {
        pendingPersistenceEvents.append(event)
        schedulePersistenceBatchIfNeeded()
    }

    private func consumePersistenceItem(_ item: PersistenceItem) async {
        switch item {
        case let .event(event):
            enqueuePersistenceBatch(event)
        case let .flush(continuation):
            await finishPersistenceBatches()
            do {
                try await persistenceFlushSink()
                continuation.resume(returning: .success(()))
            } catch {
                recordPersistenceError(error)
                continuation.resume(returning: .failure(error))
            }
        case let .reset(continuation):
            await finishPersistenceBatches()
            do {
                try await persistenceResetSink()
                continuation.resume(returning: .success(()))
            } catch {
                recordPersistenceError(error)
                continuation.resume(returning: .failure(error))
            }
        case let .scheduledFlush(generation):
            guard generation == persistenceBatchGeneration else { return }
            persistenceBatchTask = nil
            await flushPersistenceBatch()
        }
    }

    private func flushPersistenceThroughCurrentPosition() async -> Result<Void, Error> {
        guard isPersistenceStreamOpen else { return .failure(CancellationError()) }
        return await withCheckedContinuation { continuation in
            persistenceContinuation.yield(.flush(continuation))
        }
    }

    private func waitForUIWorker(_ worker: Task<Void, Never>?) async -> Bool {
        guard let worker else { return true }
        let pair = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
        let completionTask = Task {
            await worker.value
            pair.continuation.yield(true)
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: Self.maximumUIFinishWait)
            } catch {
                return
            }
            pair.continuation.yield(false)
        }
        let didFinish = await pair.stream.first(where: { _ in true }) ?? false
        completionTask.cancel()
        timeoutTask.cancel()
        pair.continuation.finish()
        return didFinish
    }

    private func deferUIReloadUntilPersistenceRecovers() {
        needsDeferredUIReload = true
        scheduleDeferredUIReloadRetryIfNeeded()
    }

    private func scheduleDeferredUIReloadRetryIfNeeded() {
        guard uiReloadRetryTask == nil, isStarted, needsDeferredUIReload else { return }
        uiReloadRetryGeneration &+= 1
        let generation = uiReloadRetryGeneration
        let delay = uiReloadRetryDelay
        uiReloadRetryDelay = min(uiReloadRetryDelay * 2, .seconds(30))
        uiReloadRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            await self?.retryDeferredUIReload(generation: generation)
        }
    }

    private func retryDeferredUIReload(generation: UInt64) async {
        guard generation == uiReloadRetryGeneration,
              needsDeferredUIReload,
              isStarted
        else { return }
        uiReloadRetryTask = nil

        let result = await flushPersistenceThroughCurrentPosition()
        guard generation == uiReloadRetryGeneration,
              needsDeferredUIReload,
              isStarted
        else { return }
        if case .success = result {
            await completeUIReload()
        } else {
            scheduleDeferredUIReloadRetryIfNeeded()
        }
    }

    private func completeUIReload() async {
        clearDeferredUIReloadState()
        let reloadSink = uiReloadSink
        let didComplete = await runBoundedUIOperation(barrierID: nil) {
            await reloadSink()
        }
        if !didComplete {
            isUILaneSuspended = true
        }
    }

    private func clearDeferredUIReloadState() {
        needsDeferredUIReload = false
        uiReloadRetryDelay = .milliseconds(250)
        cancelDeferredUIReloadRetry()
    }

    private func cancelDeferredUIReloadRetry() {
        uiReloadRetryGeneration &+= 1
        uiReloadRetryTask?.cancel()
        uiReloadRetryTask = nil
    }

    /// pipeline 終了後に persistence service の stop が回復した場合、UI 再読込だけを非同期に再開する。
    func notifyPersistenceRecoveredAfterFinish() {
        guard needsDeferredUIReload else { return }
        clearDeferredUIReloadState()
        let reloadSink = uiReloadSink
        Task { @MainActor in
            await reloadSink()
        }
    }

    private func runBoundedUIOperation(
        barrierID: UUID?,
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) async -> Bool {
        let pair = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
        let operationTask = Task { @MainActor [weak self] in
            await operation()
            pair.continuation.yield(true)
            await self?.uiOperationCompleted(barrierID: barrierID)
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: Self.maximumUIOperationWait)
            } catch {
                return
            }
            pair.continuation.yield(false)
        }
        let didComplete = await pair.stream.first(where: { _ in true }) ?? false
        timeoutTask.cancel()
        pair.continuation.finish()
        if !didComplete {
            operationTask.cancel()
        }
        return didComplete
    }

    private func uiOperationCompleted(barrierID: UUID?) {
        resumeUIBarrier(barrierID)
        guard isUILaneSuspended else { return }
        isUILaneSuspended = false
        if isAcceptingEvents {
            uiSignalContinuation.yield()
        }
    }

    private func resumeUIBarrier(_ barrierID: UUID?) {
        guard let barrierID,
              let continuation = uiBarriers.removeValue(forKey: barrierID)
        else { return }
        continuation.resume()
    }

    private func resumeAllUIBarriers() {
        let continuations = uiBarriers.values
        uiBarriers.removeAll()
        continuations.forEach { $0.resume() }
    }

    private func schedulePersistenceBatchIfNeeded() {
        guard persistenceBatchTask == nil else { return }
        persistenceBatchGeneration &+= 1
        let generation = persistenceBatchGeneration
        let persistenceBatchSleep = persistenceBatchSleep
        let persistenceContinuation = persistenceContinuation
        persistenceBatchTask = Task {
            do {
                try await persistenceBatchSleep()
            } catch {
                guard !Task.isCancelled else { return }
            }
            persistenceContinuation.yield(.scheduledFlush(generation))
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
            recordPersistenceError(error)
        }

        persistenceBatchTask = nil
        if !pendingPersistenceEvents.isEmpty {
            schedulePersistenceBatchIfNeeded()
        }
    }

    private func finishPersistenceBatches() async {
        if let task = persistenceBatchTask {
            persistenceBatchGeneration &+= 1
            persistenceBatchTask = nil
            task.cancel()
        }
        if !pendingPersistenceEvents.isEmpty {
            await flushPersistenceBatch()
        }
    }

    private func recordPersistenceError(_ error: Error) {
        if firstPersistenceError == nil {
            firstPersistenceError = error
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
