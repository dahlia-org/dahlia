import Foundation
import OSLog

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

    typealias RunningInputBundleIDsProvider = @Sendable () -> Result<Set<String>, AudioProcessObjectQueries.QueryFailure>
    typealias ChangeHandler = @MainActor @Sendable (Snapshot) -> Void
    typealias QueryFailureHandler = @MainActor @Sendable () -> Void

    private static let logger = Logger(subsystem: "com.dahlia", category: "MeetingAudioActivity")
    private static let failureLogInterval: Duration = .seconds(60)

    private let runningInputBundleIDsProvider: RunningInputBundleIDsProvider
    private let pollInterval: Duration
    private let disappearanceGracePeriod: Duration
    private var monitoringTask: Task<Void, Never>?

    init(
        pollInterval: Duration = .seconds(1),
        disappearanceGracePeriod: Duration = .seconds(4)
    ) {
        let excludedPID = ProcessInfo.processInfo.processIdentifier
        let queries = AudioProcessObjectQueries()
        self.pollInterval = pollInterval
        self.disappearanceGracePeriod = disappearanceGracePeriod
        runningInputBundleIDsProvider = {
            queries.runningInputBundleIDs(excludingPID: excludedPID)
        }
    }

    init(
        pollInterval: Duration = .seconds(1),
        disappearanceGracePeriod: Duration = .seconds(4),
        runningInputBundleIDsProvider: @escaping RunningInputBundleIDsProvider
    ) {
        self.pollInterval = pollInterval
        self.disappearanceGracePeriod = disappearanceGracePeriod
        self.runningInputBundleIDsProvider = runningInputBundleIDsProvider
    }

    func start(
        onChange: @escaping ChangeHandler,
        onQueryFailure: @escaping QueryFailureHandler = {}
    ) {
        guard monitoringTask == nil else { return }
        monitoringTask = Task { [weak self] in
            await self?.monitor(onChange: onChange, onQueryFailure: onQueryFailure)
        }
    }

    func stop() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    private func monitor(
        onChange: @escaping ChangeHandler,
        onQueryFailure: @escaping QueryFailureHandler
    ) async {
        var tracker = MeetingAudioProcessTransitionTracker(
            disappearanceGracePeriod: disappearanceGracePeriod
        )
        var nextFailureLogAt: ContinuousClock.Instant?

        while !Task.isCancelled {
            let observedAt = ContinuousClock.now
            switch runningInputBundleIDsProvider() {
            case let .success(bundleIDs):
                let contexts = MeetingAudioProcessCatalog.contexts(for: bundleIDs)
                let snapshot = tracker.observe(contexts, at: observedAt)
                await onChange(snapshot)
            case let .failure(failure):
                tracker.queryFailed()
                await onQueryFailure()
                if Self.shouldLog(at: observedAt, nextAllowedAt: &nextFailureLogAt) {
                    Self.logger.error("Failed to query running input audio processes: \(failure.description, privacy: .public)")
                }
            }

            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return
            }
        }
    }

    private static func shouldLog(
        at instant: ContinuousClock.Instant,
        nextAllowedAt: inout ContinuousClock.Instant?
    ) -> Bool {
        guard nextAllowedAt.map({ instant < $0 }) != true else { return false }
        nextAllowedAt = instant.advanced(by: failureLogInterval)
        return true
    }
}

struct MeetingAudioProcessTransitionTracker: Sendable {
    private let disappearanceGracePeriod: Duration
    private var activeContexts = Set<MeetingAudioContext>()
    private var firstSeenAt: [MeetingAudioContext: ContinuousClock.Instant] = [:]
    private var lastSeenAt: [MeetingAudioContext: ContinuousClock.Instant] = [:]
    private var absenceStartedAt: [MeetingAudioContext: ContinuousClock.Instant] = [:]
    private var hasObserved = false

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
        absenceStartedAt.removeAll()
    }
}
