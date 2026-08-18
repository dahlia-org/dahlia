import Foundation
import Observation

@MainActor
final class DahliaWindowHeaderHelpTimeline {
    static let shared = DahliaWindowHeaderHelpTimeline()

    fileprivate var lastDismissalInstant: ContinuousClock.Instant?
    fileprivate var visibleHelpIDs: Set<UUID> = []

    fileprivate func shouldPresentImmediately(
        at instant: ContinuousClock.Instant,
        within immediateSwitchWindow: Duration
    ) -> Bool {
        guard visibleHelpIDs.isEmpty else { return true }
        guard let lastDismissalInstant else { return false }
        return lastDismissalInstant.duration(to: instant) <= immediateSwitchWindow
    }
}

@MainActor
@Observable
final class DahliaWindowHeaderHelpController {
    private(set) var visibleHelpID: UUID?
    private(set) var windowBounds: CGRect = .zero
    private(set) var helpLabel = ""
    private(set) var helpShortcut: String?
    private(set) var helpButtonFrame: CGRect = .zero

    @ObservationIgnored private let displayDelay: Duration
    @ObservationIgnored private let immediateSwitchWindow: Duration
    @ObservationIgnored private let now: () -> ContinuousClock.Instant
    @ObservationIgnored private let sleep: (Duration) async throws -> Void
    @ObservationIgnored private let timeline: DahliaWindowHeaderHelpTimeline
    @ObservationIgnored private var hoveredHelpID: UUID?
    @ObservationIgnored private var pendingPresentationTask: Task<Void, Never>?

    init(
        displayDelay: Duration = .milliseconds(700),
        immediateSwitchWindow: Duration = .milliseconds(700),
        now: @escaping () -> ContinuousClock.Instant = { .now },
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        timeline: DahliaWindowHeaderHelpTimeline = .shared
    ) {
        self.displayDelay = displayDelay
        self.immediateSwitchWindow = immediateSwitchWindow
        self.now = now
        self.sleep = sleep
        self.timeline = timeline
    }

    func hoverBegan(for id: UUID) {
        hoveredHelpID = id
        pendingPresentationTask?.cancel()

        let currentInstant = now()
        if timeline.shouldPresentImmediately(
            at: currentInstant,
            within: immediateSwitchWindow
        ) {
            presentHelp(for: id)
            return
        }

        pendingPresentationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await sleep(displayDelay)
            } catch {
                return
            }
            guard !Task.isCancelled, hoveredHelpID == id else { return }
            presentHelp(for: id)
        }
    }

    func hoverBegan(
        for id: UUID,
        label: String,
        shortcut: String?,
        buttonFrame: CGRect
    ) {
        helpLabel = label
        helpShortcut = shortcut
        helpButtonFrame = buttonFrame
        hoverBegan(for: id)
    }

    func updateWindowBounds(_ bounds: CGRect) {
        windowBounds = bounds
    }

    func dismissAll() {
        hoveredHelpID = nil
        pendingPresentationTask?.cancel()
        pendingPresentationTask = nil
        dismissVisibleHelp()
    }

    func hoverEnded(for id: UUID) {
        guard hoveredHelpID == id else { return }
        hoveredHelpID = nil
        pendingPresentationTask?.cancel()
        pendingPresentationTask = nil
        if visibleHelpID == id {
            dismissVisibleHelp()
        }
    }

    private func presentHelp(for id: UUID) {
        pendingPresentationTask = nil
        if let visibleHelpID {
            timeline.visibleHelpIDs.remove(visibleHelpID)
        }
        visibleHelpID = id
        timeline.visibleHelpIDs.insert(id)
    }

    private func dismissVisibleHelp() {
        guard let visibleHelpID else { return }
        timeline.visibleHelpIDs.remove(visibleHelpID)
        self.visibleHelpID = nil
        timeline.lastDismissalInstant = now()
    }
}
