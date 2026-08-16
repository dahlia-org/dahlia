import Foundation
import Observation

@MainActor
@Observable
final class DahliaWindowHeaderHelpController {
    private(set) var visibleHelpID: UUID?
    private(set) var containerWidth: CGFloat = 0

    @ObservationIgnored private let displayDelay: Duration
    @ObservationIgnored private let immediateSwitchWindow: Duration
    @ObservationIgnored private let now: () -> ContinuousClock.Instant
    @ObservationIgnored private let sleep: (Duration) async throws -> Void
    @ObservationIgnored private var hoveredHelpID: UUID?
    @ObservationIgnored private var lastDismissalInstant: ContinuousClock.Instant?
    @ObservationIgnored private var pendingPresentationTask: Task<Void, Never>?

    init(
        displayDelay: Duration = .milliseconds(700),
        immediateSwitchWindow: Duration = .milliseconds(700),
        now: @escaping () -> ContinuousClock.Instant = { .now },
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.displayDelay = displayDelay
        self.immediateSwitchWindow = immediateSwitchWindow
        self.now = now
        self.sleep = sleep
    }

    func hoverBegan(for id: UUID) {
        hoveredHelpID = id
        pendingPresentationTask?.cancel()

        let currentInstant = now()
        if let lastDismissalInstant,
           lastDismissalInstant.duration(to: currentInstant) <= immediateSwitchWindow {
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

    func updateContainerWidth(_ width: CGFloat) {
        containerWidth = width
    }

    func hoverEnded(for id: UUID) {
        guard hoveredHelpID == id else { return }
        hoveredHelpID = nil
        pendingPresentationTask?.cancel()
        pendingPresentationTask = nil
        if visibleHelpID == id {
            visibleHelpID = nil
            lastDismissalInstant = now()
        }
    }

    private func presentHelp(for id: UUID) {
        pendingPresentationTask = nil
        visibleHelpID = id
    }
}
