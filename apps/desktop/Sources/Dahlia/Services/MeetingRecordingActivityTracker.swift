import Foundation

/// 録音中に観測した会議コンテキストを追跡し、安全条件を満たした全コンテキストの終了だけを停止候補にする。
struct MeetingRecordingActivityTracker: Sendable {
    private let minimumRuntime: Duration
    private let browserTransitionGracePeriod: Duration
    private var recordingStartedAt: ContinuousClock.Instant?
    private var contextStartedAt: [MeetingAudioContext: ContinuousClock.Instant] = [:]
    private var browserCorroborationLostAt: [MeetingAudioContext: ContinuousClock.Instant] = [:]
    private var qualifiedBrowserContexts = Set<MeetingAudioContext>()
    private var hasEligibleEndedContext = false
    private(set) var nextEvaluationDeadline: ContinuousClock.Instant?

    var isArmed: Bool { recordingStartedAt != nil }

    init(
        minimumRuntime: Duration = .seconds(30),
        browserTransitionGracePeriod: Duration = .seconds(4)
    ) {
        self.minimumRuntime = minimumRuntime
        self.browserTransitionGracePeriod = browserTransitionGracePeriod
    }

    mutating func recordingDidStart(
        at instant: ContinuousClock.Instant,
        currentSnapshot: MeetingAudioActivityMonitor.Snapshot? = nil
    ) {
        reset()
        recordingStartedAt = instant
        if let currentSnapshot {
            _ = shouldStop(after: currentSnapshot)
        }
    }

    mutating func audioObservationFailed() {
        reset()
    }

    mutating func observeBrowserCorroboration(
        browserContexts: Set<MeetingAudioContext>,
        observedAudioContexts: Set<MeetingAudioContext>,
        at instant: ContinuousClock.Instant
    ) {
        guard recordingStartedAt != nil else { return }
        let corroboratedContexts = browserContexts
            .intersection(observedAudioContexts)
            .filter(\.isBrowser)

        for context in corroboratedContexts {
            if let lostAt = browserCorroborationLostAt.removeValue(forKey: context),
               lostAt.duration(to: instant) >= browserTransitionGracePeriod,
               !qualifiedBrowserContexts.contains(context) {
                contextStartedAt[context] = instant
            }
            let startedAt = contextStartedAt[context] ?? instant
            contextStartedAt[context] = startedAt
            if startedAt.duration(to: instant) >= minimumRuntime {
                qualifiedBrowserContexts.insert(context)
            }
        }

        retainUnqualifiedBrowserTransitions(
            corroboratedContexts: corroboratedContexts,
            observedAudioContexts: observedAudioContexts,
            at: instant
        )
        updatePendingEvaluationDeadline()
    }

    mutating func shouldStop(after snapshot: MeetingAudioActivityMonitor.Snapshot) -> Bool {
        guard let recordingStartedAt else { return false }
        nextEvaluationDeadline = nil
        disarmUnqualifiedBrowserContexts(notIn: snapshot.observedContexts)
        armNativeContexts(
            snapshot.observedContexts,
            firstSeenAt: snapshot.firstSeenAt,
            at: snapshot.observedAt
        )

        for context in snapshot.endedContexts {
            if qualifiedBrowserContexts.contains(context),
               let startedAt = contextStartedAt[context],
               let lastSeenAt = snapshot.lastSeenAt[context],
               startedAt.duration(to: lastSeenAt) >= minimumRuntime {
                hasEligibleEndedContext = true
            } else if !context.isBrowser,
                      let startedAt = contextStartedAt[context],
                      let lastSeenAt = snapshot.lastSeenAt[context],
                      startedAt.duration(to: lastSeenAt) >= minimumRuntime {
                hasEligibleEndedContext = true
            }
            contextStartedAt.removeValue(forKey: context)
            qualifiedBrowserContexts.remove(context)
        }

        guard hasEligibleEndedContext,
              snapshot.activeContexts.isDisjoint(with: contextStartedAt.keys) else { return false }
        let minimumRuntimeDeadline = recordingStartedAt.advanced(by: minimumRuntime)
        guard snapshot.observedAt >= minimumRuntimeDeadline else {
            nextEvaluationDeadline = minimumRuntimeDeadline
            return false
        }

        reset()
        return true
    }

    mutating func shouldStop(at instant: ContinuousClock.Instant) -> Bool {
        guard let nextEvaluationDeadline,
              instant >= nextEvaluationDeadline else { return false }
        reset()
        return true
    }

    mutating func reset() {
        recordingStartedAt = nil
        contextStartedAt.removeAll()
        browserCorroborationLostAt.removeAll()
        qualifiedBrowserContexts.removeAll()
        hasEligibleEndedContext = false
        nextEvaluationDeadline = nil
    }

    private mutating func armNativeContexts(
        _ contexts: Set<MeetingAudioContext>,
        firstSeenAt: [MeetingAudioContext: ContinuousClock.Instant],
        at instant: ContinuousClock.Instant
    ) {
        for context in contexts where !context.isBrowser && contextStartedAt[context] == nil {
            contextStartedAt[context] = firstSeenAt[context] ?? instant
        }
    }

    private mutating func disarmUnqualifiedBrowserContexts(
        notIn observedContexts: Set<MeetingAudioContext>
    ) {
        let unobservedContexts = contextStartedAt.keys.filter { context in
            context.isBrowser
                && !qualifiedBrowserContexts.contains(context)
                && !observedContexts.contains(context)
        }
        for context in unobservedContexts {
            contextStartedAt.removeValue(forKey: context)
            browserCorroborationLostAt.removeValue(forKey: context)
        }
    }

    private mutating func retainUnqualifiedBrowserTransitions(
        corroboratedContexts: Set<MeetingAudioContext>,
        observedAudioContexts: Set<MeetingAudioContext>,
        at instant: ContinuousClock.Instant
    ) {
        let uncorroboratedContexts = contextStartedAt.keys.filter { context in
            context.isBrowser
                && !qualifiedBrowserContexts.contains(context)
                && !corroboratedContexts.contains(context)
        }
        for context in uncorroboratedContexts {
            guard observedAudioContexts.contains(context) else {
                contextStartedAt.removeValue(forKey: context)
                browserCorroborationLostAt.removeValue(forKey: context)
                continue
            }

            let lostAt = browserCorroborationLostAt[context] ?? instant
            browserCorroborationLostAt[context] = lostAt
            if lostAt.duration(to: instant) >= browserTransitionGracePeriod {
                contextStartedAt.removeValue(forKey: context)
                browserCorroborationLostAt.removeValue(forKey: context)
            }
        }
    }

    private mutating func updatePendingEvaluationDeadline() {
        guard let recordingStartedAt,
              hasEligibleEndedContext,
              contextStartedAt.isEmpty else {
            nextEvaluationDeadline = nil
            return
        }
        nextEvaluationDeadline = recordingStartedAt.advanced(by: minimumRuntime)
    }
}
