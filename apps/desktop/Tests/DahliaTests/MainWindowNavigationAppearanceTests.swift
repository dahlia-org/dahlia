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
            var projectsByID = [parent.projectId: parent, child.projectId: child]
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

            let canonicalParent = ProjectAppearance(icon: .book, color: .green)
            projectsByID[parent.projectId]?.icon = canonicalParent.icon.rawValue
            projectsByID[parent.projectId]?.color = canonicalParent.color.rawValue
            navigation.updateProjectAppearances(Array(projectsByID.values), vaultId: vault)
            #expect(navigation.projectAppearance(for: parent.projectId, in: projectsByID, vaultId: vault) == canonicalParent)
            #expect(navigation.projectAppearance(for: child.projectId, in: projectsByID, vaultId: vault) == canonicalParent)

            let explicitChild = ProjectAppearance(icon: .code, color: .pink)
            projectsByID[child.projectId]?.icon = explicitChild.icon.rawValue
            projectsByID[child.projectId]?.color = explicitChild.color.rawValue
            navigation.updateProjectAppearances(Array(projectsByID.values), vaultId: vault)
            #expect(navigation.projectAppearance(for: child.projectId, in: projectsByID, vaultId: vault) == canonicalParent)
            projectsByID[parent.projectId]?.icon = parentAppearance.icon.rawValue
            projectsByID[parent.projectId]?.color = parentAppearance.color.rawValue
            navigation.updateProjectAppearances(Array(projectsByID.values), vaultId: vault)
            #expect(navigation.projectAppearance(for: child.projectId, in: projectsByID, vaultId: vault) == parentAppearance)
            projectsByID[child.projectId]?.icon = nil
            projectsByID[child.projectId]?.color = nil
            navigation.updateProjectAppearances(Array(projectsByID.values), vaultId: vault)
            #expect(navigation.projectAppearance(for: child.projectId, in: projectsByID, vaultId: vault) == parentAppearance)
        }
    }
#endif
