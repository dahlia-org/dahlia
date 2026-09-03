#if canImport(Testing)
import Foundation
import Testing
@testable import Dahlia

@MainActor
struct MeetingSidebarHoverPresentationTests {
    @Test
    func cardUsesLocalizedDurationAndFallbacks() {
        let localizedDuration = Duration.seconds(60).formatted(
            .units(allowed: [.hours, .minutes], width: .narrow)
        )
        #expect(card(duration: 90, isActiveRecording: false).durationText == localizedDuration)
        #expect(card(duration: nil, isActiveRecording: false).durationText == "—")
        #expect(card(duration: 90, isActiveRecording: true).durationText == L10n.recordingNow)
        #expect(card(duration: 90, isActiveRecording: false).projectName == nil)
        #expect(MeetingSidebarHoverCard.descriptionLineLimit == 3)
    }

    @Test
    func layoutPlacesCardBesideRowAndConstrainsItToWindow() {
        let normal = MeetingSidebarHoverOverlay.origin(
            rowFrame: CGRect(x: 20, y: 100, width: 200, height: 30),
            cardSize: CGSize(width: 280, height: 120),
            containerOrigin: .zero,
            windowBounds: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        let constrained = MeetingSidebarHoverOverlay.origin(
            rowFrame: CGRect(x: 500, y: 580, width: 200, height: 30),
            cardSize: CGSize(width: 280, height: 120),
            containerOrigin: .zero,
            windowBounds: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        let compact = MeetingSidebarHoverOverlay.origin(
            rowFrame: CGRect(x: 20, y: 100, width: 200, height: 30),
            cardSize: CGSize(width: 280, height: 120),
            containerOrigin: .zero,
            windowBounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            rowHighlightVerticalOutset: DahliaDesign.meetingSidebarRowHighlightVerticalOutset(for: .compact)
        )
        let project = MeetingSidebarHoverOverlay.origin(
            rowFrame: CGRect(x: 20, y: 100, width: 200, height: 30),
            cardSize: CGSize(width: 280, height: 120),
            containerOrigin: .zero,
            windowBounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            rowHighlightVerticalOutset: DahliaDesign.projectSidebarRowHighlightVerticalOutset
        )

        #expect(normal == CGPoint(x: 229, y: 97))
        #expect(compact == CGPoint(x: 229, y: 96))
        #expect(project == CGPoint(x: 229, y: 96))
        #expect(constrained == CGPoint(x: 512, y: 472))
    }

    @Test
    func projectCardUsesLocalizedMeetingCount() {
        let project = ProjectOverviewItem(
            projectId: UUID.v7(),
            projectName: "Project",
            createdAt: .now,
            meetingCount: 3
        )
        let card = ProjectSidebarHoverCard(
            project: project,
            appearance: .default,
            isPinned: true,
            canEdit: true,
            onOpen: {},
            onTogglePin: {},
            onEdit: {}
        )

        #expect(card.meetingCountText == L10n.meetingCount(3))
        #expect(card.pinActionLabel == L10n.unpinProject)
        #expect(card.pinSystemImage == "pin.fill")
    }

    private func card(duration: TimeInterval?, isActiveRecording: Bool) -> MeetingSidebarHoverCard {
        MeetingSidebarHoverCard(
            item: MeetingSidebarItem(
                meetingId: UUID.v7(),
                vaultId: UUID.v7(),
                projectId: nil,
                projectName: nil,
                meetingName: "Meeting",
                status: .ready,
                duration: duration,
                createdAt: .now,
                calendarEventTitle: nil
            ),
            description: "Description",
            isActiveRecording: isActiveRecording,
            projectAppearance: nil
        )
    }
}
#endif
