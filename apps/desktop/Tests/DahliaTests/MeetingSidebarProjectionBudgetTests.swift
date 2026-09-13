#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    @MainActor
    struct MeetingSidebarProjectionBudgetTests {
        @Test
        func sharesMeetingLimitAcrossPinnedGroups() {
            let workspaceID = UUID.v7()
            let first = group(workspaceID: workspaceID, meetingCount: 4)
            let second = group(workspaceID: workspaceID, meetingCount: 4)

            let groups = MeetingListSidebarView.limitMeetingCount(in: [first, second], to: 5)

            #expect(groups.map(\.meetings.count) == [4, 1])
            #expect(groups[1].hasMore == false)
            #expect(groups[1].isLimited)
        }

        @Test
        func findsSelectedMeetingInPinnedGroups() throws {
            let group = group(workspaceID: UUID.v7(), meetingCount: 1)
            let meetingID = try #require(group.meetings.first?.meetingId)

            #expect(MeetingListSidebarView.containsMeeting(meetingID, in: [group]))
            #expect(!MeetingListSidebarView.containsMeeting(UUID.v7(), in: [group]))
        }

        private func group(workspaceID: UUID, meetingCount: Int) -> MeetingProjectGroup {
            MeetingProjectGroup(
                key: .project(UUID.v7()),
                project: nil,
                meetings: (0 ..< meetingCount).map { index in
                    MeetingSidebarItem(
                        meetingId: UUID.v7(),
                        workspaceId: workspaceID,
                        projectId: nil,
                        projectName: nil,
                        meetingName: "Meeting \(index)",
                        status: .ready,
                        duration: nil,
                        createdAt: .now,
                        calendarEventTitle: nil
                    )
                },
                hasMore: true,
                isLoadingMore: false,
                loadError: nil,
                isLimited: false
            )
        }
    }
#endif
