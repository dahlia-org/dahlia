#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    extension MainWindowNavigationTests {
        @Test
        func subprojectUsesItsParentAppearance() throws {
            let suiteName = "MainWindowNavigationTests-\(UUID.v7())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let vault = UUID.v7()
            let parent = ProjectOverviewItem(
                projectId: .v7(),
                projectName: "Parent",
                parentProjectId: nil,
                createdAt: .distantPast,
                meetingCount: 0
            )
            let child = ProjectOverviewItem(
                projectId: .v7(),
                projectName: "Parent / Child",
                parentProjectId: parent.projectId,
                createdAt: .distantPast,
                meetingCount: 0
            )
            let projectsByID = [parent.projectId: parent, child.projectId: child]
            let navigation = MainWindowNavigation(openMainWindow: {}, settingsDefaults: defaults)
            let parentAppearance = ProjectAppearance(icon: .music, color: .purple)

            navigation.setProjectAppearance(parentAppearance, projectId: parent.projectId, vaultId: vault)
            navigation.setProjectAppearance(
                ProjectAppearance(icon: .code, color: .blue),
                projectId: child.projectId,
                vaultId: vault
            )
            #expect(
                navigation.projectAppearance(for: child.projectId, in: projectsByID, vaultId: vault) == parentAppearance
            )

            let updatedAppearance = ProjectAppearance(icon: .work, color: .orange)
            navigation.setProjectAppearance(updatedAppearance, projectId: parent.projectId, vaultId: vault)
            #expect(
                navigation.projectAppearance(for: child.projectId, in: projectsByID, vaultId: vault) == updatedAppearance
            )
        }
    }
#endif
