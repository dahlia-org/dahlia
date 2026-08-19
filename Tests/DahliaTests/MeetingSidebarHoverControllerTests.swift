#if canImport(Testing)
import Foundation
import Testing
@testable import Dahlia

@MainActor
struct MeetingSidebarHoverControllerTests {
    @Test
    func waitsSevenTenthsOfASecondBeforePresentation() async {
        let sleeper = MeetingHoverTestSleeper()
        let item = makeItem()
        let rowID = UUID()
        let controller = MeetingSidebarHoverController(
            sleep: sleeper.sleep,
            loadDescription: { _, _ in "Description" }
        )

        controller.hoverBegan(
            item: item,
            isActiveRecording: false,
            rowFrame: CGRect(x: 10, y: 20, width: 100, height: 30),
            rowID: rowID
        )

        #expect(controller.visibleItem == nil)
        #expect(await pollUntil { sleeper.requestedDuration != nil })
        #expect(sleeper.requestedDuration == .milliseconds(700))

        sleeper.resume()
        #expect(await pollUntil { controller.visibleItem?.meetingId == item.meetingId })
        #expect(controller.visibleDescription == "Description")
    }

    @Test
    func hoverEndCancelsPendingPresentation() async {
        let sleeper = MeetingHoverTestSleeper()
        let item = makeItem()
        let rowID = UUID()
        let controller = MeetingSidebarHoverController(
            sleep: sleeper.sleep,
            loadDescription: { _, _ in "Description" }
        )

        controller.hoverBegan(item: item, isActiveRecording: false, rowFrame: .zero, rowID: rowID)
        #expect(await pollUntil { sleeper.requestedDuration != nil })
        controller.hoverEnded(for: item.meetingId, rowID: rowID)
        sleeper.resume()
        #expect(await pollUntil { sleeper.didReturnFromSleep })

        #expect(controller.visibleItem == nil)
    }

    @Test
    func ignoresStaleDescriptionAfterMovingToAnotherMeeting() async {
        let loader = MeetingHoverTestDescriptionLoader()
        let firstItem = makeItem()
        let secondItem = makeItem()
        let firstRowID = UUID()
        let secondRowID = UUID()
        let controller = MeetingSidebarHoverController(
            displayDelay: .zero,
            loadDescription: loader.load
        )

        controller.hoverBegan(item: firstItem, isActiveRecording: false, rowFrame: .zero, rowID: firstRowID)
        #expect(await pollUntil { loader.requestedIDs.contains(firstItem.meetingId) })
        controller.hoverBegan(item: secondItem, isActiveRecording: true, rowFrame: .zero, rowID: secondRowID)
        #expect(await pollUntil { loader.requestedIDs.contains(secondItem.meetingId) })

        loader.resume(id: firstItem.meetingId, description: "Stale")
        await Task.yield()
        #expect(controller.visibleItem == nil)

        loader.resume(id: secondItem.meetingId, description: "Current")
        #expect(await pollUntil { controller.visibleItem?.meetingId == secondItem.meetingId })
        #expect(controller.visibleDescription == "Current")
        #expect(controller.visibleIsActiveRecording)
    }

    @Test
    func projectCardWaitsForDelayAndRemainsOpenWhileHovered() async {
        let sleeper = MeetingHoverTestSleeper()
        let project = makeProject()
        let controller = MeetingSidebarHoverController(
            dismissalDelay: .zero,
            sleep: sleeper.sleep,
            loadDescription: { _, _ in nil }
        )

        controller.projectHoverBegan(
            project: project,
            appearance: .default,
            isPinned: true,
            rowFrame: CGRect(x: 10, y: 20, width: 100, height: 30)
        )

        #expect(controller.visibleProject == nil)
        #expect(await pollUntil { sleeper.requestedDuration != nil })
        #expect(sleeper.requestedDuration == .milliseconds(700))

        sleeper.resume()
        #expect(await pollUntil { controller.visibleProject?.projectId == project.projectId })
        #expect(controller.visibleProjectIsPinned)

        controller.projectRowHoverEnded(for: project.projectId)
        controller.projectCardHoverChanged(true)
        await Task.yield()
        #expect(controller.visibleProject?.projectId == project.projectId)

        controller.projectHoverBegan(
            project: project,
            appearance: .default,
            isPinned: true,
            rowFrame: .zero
        )
        controller.projectCardHoverChanged(false)
        await Task.yield()
        #expect(controller.visibleProject?.projectId == project.projectId)

        controller.projectCardHoverChanged(true)
        controller.projectRowHoverEnded(for: project.projectId)
        await Task.yield()
        #expect(controller.visibleProject?.projectId == project.projectId)

        controller.projectCardHoverChanged(false)
        #expect(await pollUntil { controller.visibleProject == nil })
    }

    @Test
    func meetingCardRemainsOpenWhileHoveredAndKeepsProjectAppearance() async {
        let sleeper = MeetingHoverTestSleeper()
        let item = makeItem()
        let rowID = UUID()
        let appearance = ProjectAppearance(icon: .code, color: .purple)
        let controller = MeetingSidebarHoverController(
            dismissalDelay: .zero,
            sleep: sleeper.sleep,
            loadDescription: { _, _ in "Description" }
        )

        controller.hoverBegan(
            item: item,
            isActiveRecording: false,
            projectAppearance: appearance,
            rowFrame: .zero,
            rowID: rowID
        )
        #expect(await pollUntil { sleeper.requestedDuration != nil })
        sleeper.resume()
        #expect(await pollUntil { controller.visibleItem?.meetingId == item.meetingId })
        #expect(controller.visibleMeetingProjectAppearance == appearance)

        controller.hoverEnded(for: item.meetingId, rowID: rowID)
        controller.meetingCardHoverChanged(true)
        await Task.yield()
        #expect(controller.visibleItem?.meetingId == item.meetingId)

        controller.hoverBegan(
            item: item,
            isActiveRecording: false,
            projectAppearance: appearance,
            rowFrame: .zero,
            rowID: rowID
        )
        controller.meetingCardHoverChanged(false)
        await Task.yield()
        #expect(controller.visibleItem?.meetingId == item.meetingId)

        controller.meetingCardHoverChanged(true)
        controller.hoverEnded(for: item.meetingId, rowID: rowID)
        await Task.yield()
        #expect(controller.visibleItem?.meetingId == item.meetingId)

        controller.meetingCardHoverChanged(false)
        #expect(await pollUntil { controller.visibleItem == nil })
    }

    @Test
    func duplicateMeetingRowCannotMoveOrDismissHoveredCard() async {
        let item = makeItem()
        let hoveredRowID = UUID()
        let duplicateRowID = UUID()
        let hoveredFrame = CGRect(x: 10, y: 20, width: 100, height: 30)
        let controller = MeetingSidebarHoverController(
            displayDelay: .zero,
            loadDescription: { _, _ in "Description" }
        )

        controller.hoverBegan(
            item: item,
            isActiveRecording: false,
            rowFrame: hoveredFrame,
            rowID: hoveredRowID
        )
        #expect(await pollUntil { controller.visibleItem?.meetingId == item.meetingId })

        controller.updateRowFrame(
            CGRect(x: 10, y: 200, width: 100, height: 30),
            for: item.meetingId,
            rowID: duplicateRowID
        )
        controller.meetingDisappeared(for: item.meetingId, rowID: duplicateRowID)

        #expect(controller.visibleRowFrame == hoveredFrame)
        #expect(controller.visibleItem?.meetingId == item.meetingId)
    }

    private func makeItem() -> MeetingSidebarItem {
        MeetingSidebarItem(
            meetingId: UUID.v7(),
            vaultId: UUID.v7(),
            projectId: nil,
            projectName: nil,
            meetingName: "Meeting",
            status: .ready,
            duration: 90,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            calendarEventTitle: nil
        )
    }

    private func makeProject() -> ProjectOverviewItem {
        ProjectOverviewItem(
            projectId: UUID.v7(),
            projectName: "Project",
            createdAt: .now,
            meetingCount: 3
        )
    }
}

@MainActor
private final class MeetingHoverTestSleeper {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var requestedDuration: Duration?
    private(set) var didReturnFromSleep = false

    func sleep(for duration: Duration) async {
        requestedDuration = duration
        await withCheckedContinuation { continuation = $0 }
        didReturnFromSleep = true
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class MeetingHoverTestDescriptionLoader {
    private var continuations: [UUID: CheckedContinuation<String?, Never>] = [:]
    private(set) var requestedIDs: [UUID] = []

    func load(meetingID: UUID, vaultID _: UUID) async -> String? {
        requestedIDs.append(meetingID)
        return await withCheckedContinuation { continuations[meetingID] = $0 }
    }

    func resume(id: UUID, description: String?) {
        continuations.removeValue(forKey: id)?.resume(returning: description)
    }
}
#endif
