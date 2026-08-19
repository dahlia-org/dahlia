import Foundation
import Observation

@MainActor
@Observable
final class MeetingSidebarHoverController {
    typealias DescriptionLoader = @MainActor @Sendable (UUID, UUID) async -> String?

    private enum HoverSource {
        case row
        case card
    }

    private(set) var visibleItem: MeetingSidebarItem?
    private(set) var visibleDescription = ""
    private(set) var visibleIsActiveRecording = false
    private(set) var visibleMeetingProjectAppearance: ProjectAppearance?
    private(set) var visibleRowFrame: CGRect = .zero
    private(set) var visibleProject: ProjectOverviewItem?
    private(set) var visibleProjectAppearance = ProjectAppearance.default
    private(set) var visibleProjectIsPinned = false

    @ObservationIgnored private let displayDelay: Duration
    @ObservationIgnored private let immediateSwitchWindow: Duration
    @ObservationIgnored private let dismissalDelay: Duration
    @ObservationIgnored private let now: () -> ContinuousClock.Instant
    @ObservationIgnored private let sleep: (Duration) async throws -> Void
    @ObservationIgnored private let loadDescription: DescriptionLoader
    @ObservationIgnored private var hoveredMeetingID: UUID?
    @ObservationIgnored private var hoveredMeetingRowID: UUID?
    @ObservationIgnored private var hoveredProjectID: UUID?
    @ObservationIgnored private var hoveredRowFrame: CGRect = .zero
    @ObservationIgnored private var meetingHoverSources: Set<HoverSource> = []
    @ObservationIgnored private var projectHoverSources: Set<HoverSource> = []
    @ObservationIgnored private var presentationTask: Task<Void, Never>?
    @ObservationIgnored private var dismissalTask: Task<Void, Never>?
    @ObservationIgnored private var lastDismissalInstant: ContinuousClock.Instant?

    init(
        displayDelay: Duration = .milliseconds(700),
        immediateSwitchWindow: Duration = .milliseconds(700),
        dismissalDelay: Duration = .milliseconds(150),
        now: @escaping () -> ContinuousClock.Instant = { .now },
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        loadDescription: @escaping DescriptionLoader
    ) {
        self.displayDelay = displayDelay
        self.immediateSwitchWindow = immediateSwitchWindow
        self.dismissalDelay = dismissalDelay
        self.now = now
        self.sleep = sleep
        self.loadDescription = loadDescription
    }

    func hoverBegan(
        item: MeetingSidebarItem,
        isActiveRecording: Bool,
        projectAppearance: ProjectAppearance? = nil,
        rowFrame: CGRect,
        rowID: UUID
    ) {
        meetingHoverSources.insert(.row)
        projectHoverSources.remove(.row)
        if hoveredMeetingID == item.meetingId,
           hoveredMeetingRowID == rowID,
           visibleItem?.meetingId == item.meetingId {
            dismissalTask?.cancel()
            dismissalTask = nil
            hoveredRowFrame = rowFrame
            visibleIsActiveRecording = isActiveRecording
            visibleMeetingProjectAppearance = projectAppearance
            visibleRowFrame = rowFrame
            return
        }

        hoveredProjectID = nil
        hoveredMeetingID = item.meetingId
        hoveredMeetingRowID = rowID
        hoveredRowFrame = rowFrame
        dismissalTask?.cancel()
        presentationTask?.cancel()
        let presentsImmediately = shouldPresentImmediately()
        dismissVisibleCard()

        let loadDescription = loadDescription
        if presentsImmediately {
            visibleItem = item
            visibleIsActiveRecording = isActiveRecording
            visibleMeetingProjectAppearance = projectAppearance
            visibleRowFrame = rowFrame
            presentationTask = Task { [weak self] in
                let loadedDescription = await loadDescription(item.meetingId, item.vaultId)
                guard !Task.isCancelled,
                      let self,
                      hoveredMeetingID == item.meetingId,
                      hoveredMeetingRowID == rowID else { return }
                visibleDescription = loadedDescription ?? ""
                presentationTask = nil
            }
            return
        }

        let displayDelay = displayDelay
        let sleep = sleep
        presentationTask = Task { [weak self] in
            async let description = loadDescription(item.meetingId, item.vaultId)
            do {
                try await sleep(displayDelay)
            } catch {
                return
            }
            let loadedDescription = await description
            guard !Task.isCancelled,
                  let self,
                  hoveredMeetingID == item.meetingId,
                  hoveredMeetingRowID == rowID else { return }
            visibleItem = item
            visibleDescription = loadedDescription ?? ""
            visibleIsActiveRecording = isActiveRecording
            visibleMeetingProjectAppearance = projectAppearance
            visibleRowFrame = hoveredRowFrame
            presentationTask = nil
        }
    }

    func projectHoverBegan(
        project: ProjectOverviewItem,
        appearance: ProjectAppearance,
        isPinned: Bool,
        rowFrame: CGRect
    ) {
        meetingHoverSources.remove(.row)
        projectHoverSources.insert(.row)
        if hoveredProjectID == project.projectId,
           visibleProject?.projectId == project.projectId {
            dismissalTask?.cancel()
            dismissalTask = nil
            hoveredRowFrame = rowFrame
            visibleProjectAppearance = appearance
            visibleProjectIsPinned = isPinned
            visibleRowFrame = rowFrame
            return
        }

        hoveredMeetingID = nil
        hoveredMeetingRowID = nil
        hoveredProjectID = project.projectId
        hoveredRowFrame = rowFrame
        dismissalTask?.cancel()
        presentationTask?.cancel()
        let presentsImmediately = shouldPresentImmediately()
        dismissVisibleCard()

        if presentsImmediately {
            visibleProject = project
            visibleProjectAppearance = appearance
            visibleProjectIsPinned = isPinned
            visibleRowFrame = rowFrame
            return
        }

        let displayDelay = displayDelay
        let sleep = sleep
        presentationTask = Task { [weak self] in
            do {
                try await sleep(displayDelay)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  hoveredProjectID == project.projectId else { return }
            visibleProject = project
            visibleProjectAppearance = appearance
            visibleProjectIsPinned = isPinned
            visibleRowFrame = hoveredRowFrame
            presentationTask = nil
        }
    }

    func updateRowFrame(_ rowFrame: CGRect, for meetingID: UUID, rowID: UUID) {
        guard hoveredMeetingID == meetingID,
              hoveredMeetingRowID == rowID else { return }
        hoveredRowFrame = rowFrame
        if visibleItem?.meetingId == meetingID {
            visibleRowFrame = rowFrame
        }
    }

    func updateProjectRowFrame(_ rowFrame: CGRect, for projectID: UUID) {
        guard hoveredProjectID == projectID else { return }
        hoveredRowFrame = rowFrame
        if visibleProject?.projectId == projectID {
            visibleRowFrame = rowFrame
        }
    }

    func hoverEnded(for meetingID: UUID, rowID: UUID) {
        guard hoveredMeetingID == meetingID,
              hoveredMeetingRowID == rowID else { return }
        meetingHoverSources.remove(.row)
        guard visibleItem?.meetingId == meetingID else {
            dismissAll()
            return
        }
        scheduleMeetingDismissal(for: meetingID, rowID: rowID)
    }

    func meetingDisappeared(for meetingID: UUID, rowID: UUID) {
        guard hoveredMeetingID == meetingID,
              hoveredMeetingRowID == rowID else { return }
        dismissAll()
    }

    func meetingCardHoverChanged(_ isHovered: Bool) {
        if isHovered {
            meetingHoverSources.insert(.card)
            dismissalTask?.cancel()
            dismissalTask = nil
        } else {
            meetingHoverSources.remove(.card)
            if let meetingID = hoveredMeetingID,
               let rowID = hoveredMeetingRowID {
                scheduleMeetingDismissal(for: meetingID, rowID: rowID)
            }
        }
    }

    func projectRowHoverEnded(for projectID: UUID) {
        guard hoveredProjectID == projectID else { return }
        projectHoverSources.remove(.row)
        guard visibleProject?.projectId == projectID else {
            dismissAll()
            return
        }
        scheduleProjectDismissal(for: projectID)
    }

    func projectDisappeared(for projectID: UUID) {
        guard hoveredProjectID == projectID else { return }
        dismissAll()
    }

    func projectCardHoverChanged(_ isHovered: Bool) {
        if isHovered {
            projectHoverSources.insert(.card)
            dismissalTask?.cancel()
            dismissalTask = nil
        } else {
            projectHoverSources.remove(.card)
            if let projectID = hoveredProjectID {
                scheduleProjectDismissal(for: projectID)
            }
        }
    }

    func dismissAll() {
        hoveredMeetingID = nil
        hoveredMeetingRowID = nil
        hoveredProjectID = nil
        meetingHoverSources.removeAll()
        projectHoverSources.removeAll()
        presentationTask?.cancel()
        presentationTask = nil
        dismissalTask?.cancel()
        dismissalTask = nil
        dismissVisibleCard()
    }

    private func dismissVisibleCard() {
        let hadVisibleCard = visibleItem != nil || visibleProject != nil
        meetingHoverSources.remove(.card)
        projectHoverSources.remove(.card)
        visibleItem = nil
        visibleDescription = ""
        visibleIsActiveRecording = false
        visibleMeetingProjectAppearance = nil
        visibleRowFrame = .zero
        visibleProject = nil
        visibleProjectAppearance = .default
        visibleProjectIsPinned = false
        if hadVisibleCard {
            lastDismissalInstant = now()
        }
    }

    private func shouldPresentImmediately() -> Bool {
        guard visibleItem == nil, visibleProject == nil else { return true }
        guard let lastDismissalInstant else { return false }
        return lastDismissalInstant.duration(to: now()) <= immediateSwitchWindow
    }

    private func scheduleMeetingDismissal(for meetingID: UUID, rowID: UUID) {
        guard meetingHoverSources.isEmpty else { return }
        dismissalTask?.cancel()
        let dismissalDelay = dismissalDelay
        dismissalTask = Task { [weak self] in
            do {
                try await Task.sleep(for: dismissalDelay)
            } catch {
                return
            }
            guard let self,
                  hoveredMeetingID == meetingID,
                  hoveredMeetingRowID == rowID,
                  meetingHoverSources.isEmpty else { return }
            dismissAll()
        }
    }

    private func scheduleProjectDismissal(for projectID: UUID) {
        guard projectHoverSources.isEmpty else { return }
        dismissalTask?.cancel()
        let dismissalDelay = dismissalDelay
        dismissalTask = Task { [weak self] in
            do {
                try await Task.sleep(for: dismissalDelay)
            } catch {
                return
            }
            guard let self,
                  hoveredProjectID == projectID,
                  projectHoverSources.isEmpty else { return }
            dismissAll()
        }
    }
}
