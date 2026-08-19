#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    @MainActor
    struct ProjectCatalogViewTests {
        @Test
        func filtersByPathAndSortsByLatestActivity() {
            let olderMatch = project(named: "Customer/Older", createdAt: Date(timeIntervalSince1970: 100))
            let newerMatch = project(
                named: "Customer/Newer",
                createdAt: Date(timeIntervalSince1970: 50),
                latestMeetingDate: Date(timeIntervalSince1970: 200)
            )
            let other = project(named: "Internal", createdAt: Date(timeIntervalSince1970: 300))

            let result = ProjectCatalogView.projects([olderMatch, other, newerMatch], matching: "customer")

            #expect(result.map(\.projectId) == [newerMatch.projectId, olderMatch.projectId])
        }

        private func project(named name: String, createdAt: Date, latestMeetingDate: Date? = nil) -> ProjectOverviewItem {
            ProjectOverviewItem(
                projectId: .v7(),
                projectName: name,
                projectDisplayName: name.split(separator: "/").last.map(String.init) ?? name,
                parentProjectId: nil,
                projectDescription: "",
                explicitProjectType: .undefined,
                effectiveProjectType: .undefined,
                typeOwnerProjectId: nil,
                revision: 1,
                createdAt: createdAt,
                meetingCount: 0,
                latestMeetingDate: latestMeetingDate
            )
        }
    }
#endif
