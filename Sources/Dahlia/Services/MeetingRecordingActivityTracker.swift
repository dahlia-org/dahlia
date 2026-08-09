import Foundation

/// 録音中に観測した会議コンテキストを追跡し、安全条件を満たした全コンテキストの終了だけを停止候補にする。
struct MeetingRecordingActivityTracker: Sendable {
    private let minimumRuntime: Duration
    private var recordingStartedAt: ContinuousClock.Instant?
    private var contextStartedAt: [MeetingAudioContext: ContinuousClock.Instant] = [:]
    private var qualifiedBrowserContexts = Set<MeetingAudioContext>()
    private var hasEligibleEndedContext = false

    var isArmed: Bool { recordingStartedAt != nil }

    init(minimumRuntime: Duration = .seconds(30)) {
        self.minimumRuntime = minimumRuntime
    }

    mutating func recordingDidStart(at instant: ContinuousClock.Instant) {
        reset()
        recordingStartedAt = instant
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
            let startedAt = contextStartedAt[context] ?? instant
            contextStartedAt[context] = startedAt
            if startedAt.duration(to: instant) >= minimumRuntime {
                qualifiedBrowserContexts.insert(context)
            }
        }

        disarmUnqualifiedBrowserContexts(notIn: corroboratedContexts)
    }

    mutating func shouldStop(after snapshot: MeetingAudioActivityMonitor.Snapshot) -> Bool {
        guard let recordingStartedAt else { return false }
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

        guard recordingStartedAt.duration(to: snapshot.observedAt) >= minimumRuntime,
              hasEligibleEndedContext,
              snapshot.activeContexts.isDisjoint(with: contextStartedAt.keys) else { return false }

        reset()
        return true
    }

    mutating func reset() {
        recordingStartedAt = nil
        contextStartedAt.removeAll()
        qualifiedBrowserContexts.removeAll()
        hasEligibleEndedContext = false
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
        }
    }
}
