import Foundation
#if canImport(Testing)
    import Testing
    @testable import Dahlia

    @MainActor
    struct ProjectDeletionDialogTests {
        @Test
        func deletesProjectWithoutMeetings() {
            let disposition = ProjectDeletionDialog.meetingDisposition(
                meetingCount: 0,
                deletesMeetings: false,
                selectedDestinationId: nil
            )

            #expect(disposition == .deleteMeetings)
        }

        @Test
        func deletesMeetingsWhenRequested() {
            let disposition = ProjectDeletionDialog.meetingDisposition(
                meetingCount: 2,
                deletesMeetings: true,
                selectedDestinationId: nil
            )

            #expect(disposition == .deleteMeetings)
        }

        @Test
        func movesMeetingsToSelectedDestination() {
            let destinationId = UUID.v7()
            let disposition = ProjectDeletionDialog.meetingDisposition(
                meetingCount: 2,
                deletesMeetings: false,
                selectedDestinationId: destinationId
            )

            #expect(disposition == .move(to: destinationId))
        }

        @Test
        func requiresDestinationBeforeMovingMeetings() {
            let disposition = ProjectDeletionDialog.meetingDisposition(
                meetingCount: 2,
                deletesMeetings: false,
                selectedDestinationId: nil
            )

            #expect(disposition == nil)
        }

        @Test
        func deletingRootWithChildCanMoveMeetingsOutsideHierarchy() {
            let projects = projectHierarchy()
            let source = projects[0]

            let destinations = ProjectDestinationOptions.meetingMoveCandidates(
                whenDeleting: source,
                projects: projects
            )

            #expect(destinations.map(\.projectName) == ["Destination", "Destination/Child"])
            #expect(ProjectDestinationOptions.reparentCandidates(for: source, projects: projects).isEmpty)
        }

        @Test
        func deletingLeafCanMoveMeetingsToRootOrAnotherSubproject() {
            let projects = projectHierarchy()
            let sourceChild = projects[1]

            let destinations = ProjectDestinationOptions.meetingMoveCandidates(
                whenDeleting: sourceChild,
                projects: projects
            )

            #expect(destinations.map(\.projectName) == ["Source", "Destination", "Destination/Child"])
        }

        private func projectHierarchy() -> [ProjectOverviewItem] {
            let sourceID = UUID.v7()
            let destinationID = UUID.v7()
            return [
                project(id: sourceID, name: "Source"),
                project(id: .v7(), name: "Source/Child", parentId: sourceID),
                project(id: destinationID, name: "Destination"),
                project(id: .v7(), name: "Destination/Child", parentId: destinationID),
            ]
        }

        private func project(
            id: UUID,
            name: String,
            parentId: UUID? = nil
        ) -> ProjectOverviewItem {
            ProjectOverviewItem(
                projectId: id,
                projectName: name,
                projectLeafName: name.split(separator: "/").last.map(String.init) ?? name,
                parentProjectId: parentId,
                createdAt: .now,
                meetingCount: 0,
                latestMeetingDate: nil
            )
        }
    }
#endif
