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
            var parent = ProjectOverviewItem(
                projectId: .v7(),
                projectName: "Parent",
                parentProjectId: nil,
                createdAt: .distantPast,
                meetingCount: 0
            )
            var child = ProjectOverviewItem(
                projectId: .v7(),
                projectName: "Parent / Child",
                parentProjectId: parent.projectId,
                createdAt: .distantPast,
                meetingCount: 0
            )
            let projectsByID = [parent.projectId: parent, child.projectId: child]
            let navigation = MainWindowNavigation(openMainWindow: {}, settingsDefaults: defaults)
            let parentAppearance = ProjectAppearance(icon: .music, color: .purple)

            parent.icon = parentAppearance.icon.rawValue
            parent.color = parentAppearance.color.rawValue
            child.icon = ProjectIcon.code.rawValue
            child.color = ProjectThemeColor.blue.rawValue
            navigation.updateProjectAppearances([parent, child], vaultId: vault)
            #expect(
                navigation.projectAppearance(for: child.projectId, in: projectsByID, vaultId: vault) == parentAppearance
            )

            let updatedAppearance = ProjectAppearance(icon: .work, color: .orange)
            parent.icon = updatedAppearance.icon.rawValue
            parent.color = updatedAppearance.color.rawValue
            navigation.updateProjectAppearances([parent, child], vaultId: vault)
            #expect(
                navigation.projectAppearance(for: child.projectId, in: projectsByID, vaultId: vault) == updatedAppearance
            )
        }
    }
#endif
