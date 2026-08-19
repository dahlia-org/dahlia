import Foundation
import Observation

@MainActor
@Observable
final class MeetingSidebarHoverController {
    typealias DescriptionLoader = @MainActor @Sendable (UUID, UUID) async -> String?

    private(set) var visibleItem: MeetingSidebarItem?
    private(set) var visibleDescription = ""
    private(set) var visibleIsActiveRecording = false
    private(set) var visibleMeetingProjectAppearance: ProjectAppearance?
    private(set) var visibleRowFrame: CGRect = .zero
    private(set) var visibleProject: ProjectOverviewItem?
    private(set) var visibleProjectAppearance = ProjectAppearance.default
    private(set) var visibleProjectIsPinned = false

    @ObservationIgnored private let displayDelay: Duration
    @ObservationIgnored private let sleep: (Duration) async throws -> Void
    @ObservationIgnored private let loadDescription: DescriptionLoader
    @ObservationIgnored private var hoveredMeetingID: UUID?
    @ObservationIgnored private var hoveredMeetingRowID: UUID?
    @ObservationIgnored private var hoveredProjectID: UUID?
    @ObservationIgnored private var hoveredRowFrame: CGRect = .zero
    @ObservationIgnored private var presentationTask: Task<Void, Never>?
    @ObservationIgnored private var dismissalTask: Task<Void, Never>?

    init(
        displayDelay: Duration = .milliseconds(700),
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        loadDescription: @escaping DescriptionLoader
    ) {
        self.displayDelay = displayDelay
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
        dismissVisibleCard()

        let displayDelay = displayDelay
        let sleep = sleep
        let loadDescription = loadDescription
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
        dismissVisibleCard()

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
        guard visibleItem?.meetingId == meetingID else {
            dismissAll()
            return
        }
        dismissalTask?.cancel()
        dismissalTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            guard let self,
                  hoveredMeetingID == meetingID,
                  hoveredMeetingRowID == rowID else { return }
            dismissAll()
        }
    }

    func meetingDisappeared(for meetingID: UUID, rowID: UUID) {
        guard hoveredMeetingID == meetingID,
              hoveredMeetingRowID == rowID else { return }
        dismissAll()
    }

    func meetingCardHoverChanged(_ isHovered: Bool) {
        if isHovered {
            dismissalTask?.cancel()
            dismissalTask = nil
        } else if let meetingID = hoveredMeetingID,
                  let rowID = hoveredMeetingRowID {
            hoverEnded(for: meetingID, rowID: rowID)
        }
    }

    func projectRowHoverEnded(for projectID: UUID) {
        guard hoveredProjectID == projectID else { return }
        guard visibleProject?.projectId == projectID else {
            dismissAll()
            return
        }
        dismissalTask?.cancel()
        dismissalTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            guard let self, hoveredProjectID == projectID else { return }
            dismissAll()
        }
    }

    func projectDisappeared(for projectID: UUID) {
        guard hoveredProjectID == projectID else { return }
        dismissAll()
    }

    func projectCardHoverChanged(_ isHovered: Bool) {
        if isHovered {
            dismissalTask?.cancel()
            dismissalTask = nil
        } else if let projectID = hoveredProjectID {
            projectRowHoverEnded(for: projectID)
        }
    }

    func dismissAll() {
        hoveredMeetingID = nil
        hoveredMeetingRowID = nil
        hoveredProjectID = nil
        presentationTask?.cancel()
        presentationTask = nil
        dismissalTask?.cancel()
        dismissalTask = nil
        dismissVisibleCard()
    }

    private func dismissVisibleCard() {
        visibleItem = nil
        visibleDescription = ""
        visibleIsActiveRecording = false
        visibleMeetingProjectAppearance = nil
        visibleRowFrame = .zero
        visibleProject = nil
        visibleProjectAppearance = .default
        visibleProjectIsPinned = false
    }
}
