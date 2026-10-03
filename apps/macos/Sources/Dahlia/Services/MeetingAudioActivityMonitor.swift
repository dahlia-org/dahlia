import Foundation

/// CoreAudio が公開する入力中プロセスを正規化し、会議コンテキストの開始・終了遷移を一つの経路で通知する。
actor MeetingAudioActivityMonitor {
    struct Snapshot: Sendable {
        let observedContexts: Set<MeetingAudioContext>
        let activeContexts: Set<MeetingAudioContext>
        let startedContexts: Set<MeetingAudioContext>
        let endedContexts: Set<MeetingAudioContext>
        let firstSeenAt: [MeetingAudioContext: ContinuousClock.Instant]
        let lastSeenAt: [MeetingAudioContext: ContinuousClock.Instant]
        let observedAt: ContinuousClock.Instant
        let isInitial: Bool
    }

    typealias ChangeHandler = @MainActor @Sendable (Snapshot) -> Void
    typealias QueryFailureHandler = @MainActor @Sendable () -> Void
    typealias SleepUntil = @Sendable (ContinuousClock.Instant) async throws -> Void

    private let activityMonitor: AudioProcessActivityMonitor
    private let pollInterval: Duration
    private let disappearanceGracePeriod: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleepUntil: SleepUntil
    private var tracker: MeetingAudioProcessTransitionTracker
    private var observerID: UUID?
    private var onChange: ChangeHandler?
    private var onQueryFailure: QueryFailureHandler?
    private var pollTask: Task<Void, Never>?
    private var graceTask: Task<Void, Never>?
    private var graceDeadline: ContinuousClock.Instant?
    private var observedContexts = Set<MeetingAudioContext>()
    private var monitoringGeneration: UInt64 = 0
    private var isMonitoring = false
    private var hasValidObservation = false

    init(
        pollInterval: Duration = .seconds(1),
        disappearanceGracePeriod: Duration = .seconds(4),
        activityMonitor: AudioProcessActivityMonitor = .shared,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        sleepUntil: @escaping SleepUntil = { deadline in
            try await ContinuousClock().sleep(until: deadline)
        }
    ) {
        self.activityMonitor = activityMonitor
        self.pollInterval = pollInterval
        self.disappearanceGracePeriod = disappearanceGracePeriod
        self.now = now
        self.sleepUntil = sleepUntil
        tracker = MeetingAudioProcessTransitionTracker(disappearanceGracePeriod: disappearanceGracePeriod)
    }

    func start(
        onChange: @escaping ChangeHandler,
        onQueryFailure: @escaping QueryFailureHandler = {}
    ) async {
        guard !isMonitoring else { return }
        isMonitoring = true
        monitoringGeneration &+= 1
        let generation = monitoringGeneration
        tracker = MeetingAudioProcessTransitionTracker(disappearanceGracePeriod: disappearanceGracePeriod)
        observedContexts.removeAll()
        hasValidObservation = false
        self.onChange = onChange
        self.onQueryFailure = onQueryFailure

        let id = await activityMonitor.addRunningInputObserver { [weak self] result in
            await self?.handle(result, generation: generation)
        }
        guard isMonitoring, generation == monitoringGeneration else {
            await activityMonitor.removeRunningInputObserver(id)
            return
        }
        observerID = id
        pollTask = Task { [weak self] in
            await self?.pollRunningInputState(generation: generation)
        }
    }

    func stop() async {
        guard isMonitoring else { return }
        isMonitoring = false
        monitoringGeneration &+= 1
        pollTask?.cancel()
        pollTask = nil
        cancelGraceEvaluation()
        onChange = nil
        onQueryFailure = nil
        hasValidObservation = false
        tracker = MeetingAudioProcessTransitionTracker(disappearanceGracePeriod: disappearanceGracePeriod)

        if let observerID {
            self.observerID = nil
            await activityMonitor.removeRunningInputObserver(observerID)
        }
    }

    private func pollRunningInputState(generation: UInt64) async {
        while isMonitoring, generation == monitoringGeneration, !Task.isCancelled {
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return
            }
            guard isMonitoring, generation == monitoringGeneration else { return }
            await activityMonitor.refreshRunningInputState()
        }
    }

    private func handle(
        _ result: AudioProcessActivityMonitor.RunningInputBundleIDsResult,
        generation: UInt64
    ) async {
        guard isMonitoring, generation == monitoringGeneration else { return }

        switch result {
        case let .success(bundleIDs):
            let contexts = MeetingAudioProcessCatalog.contexts(for: bundleIDs)
            guard !hasValidObservation || contexts != observedContexts else { return }
            hasValidObservation = true
            observedContexts = contexts
            await publishObservation(at: now(), generation: generation)
        case .failure:
            hasValidObservation = false
            tracker.queryFailed()
            cancelGraceEvaluation()
            if let onQueryFailure {
                await onQueryFailure()
            }
        }
    }

    private func publishObservation(
        at instant: ContinuousClock.Instant,
        generation: UInt64
    ) async {
        let snapshot = tracker.observe(observedContexts, at: instant)
        if let onChange {
            await onChange(snapshot)
        }
        guard isMonitoring, generation == monitoringGeneration else { return }
        scheduleGraceEvaluation(generation: generation)
    }

    private func scheduleGraceEvaluation(generation: UInt64) {
        let deadline = tracker.nextDisappearanceDeadline
        guard deadline != graceDeadline else { return }
        cancelGraceEvaluation()
        graceDeadline = deadline
        guard let deadline else { return }

        graceTask = Task { [weak self, sleepUntil] in
            do {
                try await sleepUntil(deadline)
            } catch {
                return
            }
            await self?.gracePeriodEnded(deadline: deadline, generation: generation)
        }
    }

    private func gracePeriodEnded(
        deadline: ContinuousClock.Instant,
        generation: UInt64
    ) async {
        guard isMonitoring,
              generation == monitoringGeneration,
              deadline == graceDeadline else { return }
        graceTask = nil
        graceDeadline = nil
        await publishObservation(at: now(), generation: generation)
    }

    private func cancelGraceEvaluation() {
        graceTask?.cancel()
        graceTask = nil
        graceDeadline = nil
    }
}

struct MeetingAudioProcessTransitionTracker: Sendable {
    private let disappearanceGracePeriod: Duration
    private var activeContexts = Set<MeetingAudioContext>()
    private var firstSeenAt: [MeetingAudioContext: ContinuousClock.Instant] = [:]
    private var lastSeenAt: [MeetingAudioContext: ContinuousClock.Instant] = [:]
    private var absenceStartedAt: [MeetingAudioContext: ContinuousClock.Instant] = [:]
    private var hasObserved = false

    var nextDisappearanceDeadline: ContinuousClock.Instant? {
        absenceStartedAt.values.min()?.advanced(by: disappearanceGracePeriod)
    }

    init(disappearanceGracePeriod: Duration = .seconds(4)) {
        self.disappearanceGracePeriod = disappearanceGracePeriod
    }

    mutating func observe(
        _ observedContexts: Set<MeetingAudioContext>,
        at instant: ContinuousClock.Instant
    ) -> MeetingAudioActivityMonitor.Snapshot {
        for context in observedContexts {
            firstSeenAt[context] = firstSeenAt[context] ?? instant
            lastSeenAt[context] = instant
            absenceStartedAt.removeValue(forKey: context)
        }

        let missingContexts = activeContexts.subtracting(observedContexts)
        for context in missingContexts where absenceStartedAt[context] == nil {
            absenceStartedAt[context] = instant
            lastSeenAt[context] = instant
        }
        let retainedContexts = Set(missingContexts.filter { context in
            guard let absentSince = absenceStartedAt[context] else { return false }
            return absentSince.duration(to: instant) < disappearanceGracePeriod
        })
        let nextActiveContexts = observedContexts.union(retainedContexts)
        let isInitial = !hasObserved
        let startedContexts = isInitial ? [] : nextActiveContexts.subtracting(activeContexts)
        let endedContexts = activeContexts.subtracting(nextActiveContexts)
        let snapshotFirstSeenAt = firstSeenAt
        let snapshotLastSeenAt = lastSeenAt

        for context in endedContexts {
            firstSeenAt.removeValue(forKey: context)
            lastSeenAt.removeValue(forKey: context)
            absenceStartedAt.removeValue(forKey: context)
        }
        activeContexts = nextActiveContexts
        hasObserved = true

        return MeetingAudioActivityMonitor.Snapshot(
            observedContexts: observedContexts,
            activeContexts: nextActiveContexts,
            startedContexts: startedContexts,
            endedContexts: endedContexts,
            firstSeenAt: snapshotFirstSeenAt,
            lastSeenAt: snapshotLastSeenAt,
            observedAt: instant,
            isInitial: isInitial
        )
    }

    mutating func queryFailed() {
        activeContexts.removeAll()
        firstSeenAt.removeAll()
        lastSeenAt.removeAll()
        absenceStartedAt.removeAll()
        hasObserved = false
    }
}
