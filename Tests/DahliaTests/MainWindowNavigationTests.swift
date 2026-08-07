#if canImport(Testing)
import Foundation
import Testing
@testable import Dahlia

@MainActor
struct MainWindowNavigationTests {
    @Test
    func switchesBetweenMeetingAndProjectSections() {
        let navigation = MainWindowNavigation(openMainWindow: {})

        #expect(navigation.section == .meetings)

        navigation.showProjects()
        #expect(navigation.section == .projects)

        navigation.showMeetings()
        #expect(navigation.section == .meetings)
    }

    @Test
    func openingProjectsSetsSectionBeforeOpeningMainWindow() {
        var observedSection: MainWindowSection?
        var navigation: MainWindowNavigation?
        let subject = MainWindowNavigation {
            observedSection = navigation?.section
        }
        navigation = subject

        subject.openProjects()

        #expect(observedSection == .projects)
    }

    @Test
    func openingMeetingsSetsSectionBeforeOpeningMainWindow() {
        var observedSection: MainWindowSection?
        var navigation: MainWindowNavigation?
        let subject = MainWindowNavigation {
            observedSection = navigation?.section
        }
        navigation = subject
        subject.showProjects()

        subject.openMeetings()

        #expect(observedSection == .meetings)
    }

    @Test
    func projectPresentationStateSurvivesSectionRoundTrip() {
        let navigation = MainWindowNavigation(openMainWindow: {})
        let projectId = UUID.v7()
        let expandedId = UUID.v7()
        navigation.selectedProjectId = projectId
        navigation.projectSearchText = "customer"
        navigation.expandedProjectIds = [expandedId]

        navigation.showMeetings()
        navigation.showProjects()

        #expect(navigation.selectedProjectId == projectId)
        #expect(navigation.projectSearchText == "customer")
        #expect(navigation.expandedProjectIds == [expandedId])
    }

    @Test
    func changingVaultResetsProjectPresentationState() {
        let navigation = MainWindowNavigation(openMainWindow: {})
        let firstVaultId = UUID.v7()
        let secondVaultId = UUID.v7()
        let firstProject = project(named: "First")
        let secondProject = project(named: "Second")
        navigation.reconcileProjectCatalog(vaultId: firstVaultId, projects: [firstProject])
        navigation.projectSearchText = "first"
        navigation.expandedProjectIds = [firstProject.projectId]

        navigation.reconcileProjectCatalog(vaultId: secondVaultId, projects: [secondProject])

        #expect(navigation.selectedProjectId == secondProject.projectId)
        #expect(navigation.projectSearchText.isEmpty)
        #expect(navigation.expandedProjectIds.isEmpty)
    }

    @Test
    func deletingSelectedProjectSelectsFirstRemainingProjectInSameVault() {
        let navigation = MainWindowNavigation(openMainWindow: {})
        let vaultId = UUID.v7()
        let first = project(named: "First")
        let selected = project(named: "Selected")
        navigation.reconcileProjectCatalog(vaultId: vaultId, projects: [first, selected])
        navigation.selectedProjectId = selected.projectId

        navigation.reconcileProjectCatalog(vaultId: vaultId, projects: [first])

        #expect(navigation.selectedProjectId == first.projectId)
    }

    private func project(named name: String) -> ProjectOverviewItem {
        ProjectOverviewItem(
            projectId: .v7(),
            projectName: name,
            projectDisplayName: name,
            parentProjectId: nil,
            projectDescription: "",
            explicitProjectType: .undefined,
            effectiveProjectType: .undefined,
            typeOwnerProjectId: nil,
            revision: 0,
            createdAt: .now,
            meetingCount: 0,
            latestMeetingDate: nil
        )
    }
}
#endif
