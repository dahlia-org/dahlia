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
    func navigatesBackwardAndForwardThroughMainLocations() async {
        let navigation = MainWindowNavigation(openMainWindow: {})
        let meetingId = UUID.v7()
        let projectId = UUID.v7()
        navigation.recordNavigation(to: .meeting(meetingId))
        navigation.recordNavigation(to: .project(projectId))
        navigation.recordNavigation(to: .unprocessedRecordings)

        await navigateBack(navigation)
        #expect(navigation.currentLocation == .project(projectId))
        #expect(navigation.section == .projects)

        await navigateBack(navigation)
        #expect(navigation.currentLocation == .meeting(meetingId))

        await navigateBack(navigation)
        #expect(navigation.currentLocation == .upcomingSchedule)
        #expect(!navigation.canGoBack)

        await navigateForward(navigation)
        await navigateForward(navigation)
        await navigateForward(navigation)
        #expect(navigation.currentLocation == .unprocessedRecordings)
        #expect(!navigation.canGoForward)
    }

    @Test
    func duplicateNavigationDoesNotAddHistory() async {
        let navigation = MainWindowNavigation(openMainWindow: {})
        let meetingId = UUID.v7()

        navigation.recordNavigation(to: .meeting(meetingId))
        navigation.recordNavigation(to: .meeting(meetingId))
        await navigateBack(navigation)

        #expect(navigation.currentLocation == .upcomingSchedule)
        #expect(!navigation.canGoBack)
    }

    @Test
    func repeatedInitializationKeepsExistingBackAndForwardHistory() async {
        let navigation = MainWindowNavigation(openMainWindow: {})
        let meetingId = UUID.v7()
        navigation.initializeNavigationHistoryIfNeeded(to: .upcomingSchedule)
        navigation.recordNavigation(to: .meeting(meetingId))
        navigation.recordNavigation(to: .project(.v7()))
        await navigateBack(navigation)

        navigation.initializeNavigationHistoryIfNeeded(to: .unprocessedRecordings)

        #expect(navigation.currentLocation == .meeting(meetingId))
        #expect(navigation.canGoBack)
        #expect(navigation.canGoForward)
    }

    @Test
    func newNavigationAfterGoingBackClearsForwardHistory() async {
        let navigation = MainWindowNavigation(openMainWindow: {})
        navigation.recordNavigation(to: .meeting(.v7()))
        navigation.recordNavigation(to: .project(.v7()))

        await navigateBack(navigation)
        #expect(navigation.canGoForward)

        navigation.recordNavigation(to: .unprocessedRecordings)

        #expect(!navigation.canGoForward)
    }

    @Test
    func resettingHistoryForVaultChangeClearsBothDirections() async {
        let navigation = MainWindowNavigation(openMainWindow: {})
        let vaultId = UUID.v7()
        navigation.recordNavigation(to: .meeting(.v7()))
        navigation.recordNavigation(to: .project(.v7()))
        navigation.recordNavigation(to: .unprocessedRecordings)
        navigation.projectSearchText = "customer"
        navigation.expandedProjectIds = [.v7()]
        await navigateBack(navigation)

        navigation.changeVault(to: vaultId)

        #expect(navigation.currentLocation == .project(nil))
        #expect(!navigation.canGoBack)
        #expect(!navigation.canGoForward)
        #expect(navigation.selectedProjectId == nil)
        #expect(navigation.projectSearchText.isEmpty)
        #expect(navigation.expandedProjectIds.isEmpty)
    }

    @Test
    func changingVaultKeepsUnprocessedRecordingsAsCurrentLocation() {
        let navigation = MainWindowNavigation(openMainWindow: {})
        navigation.recordNavigation(to: .unprocessedRecordings)

        navigation.changeVault(to: .v7())

        #expect(navigation.currentLocation == .unprocessedRecordings)
        #expect(!navigation.canGoBack)
        #expect(!navigation.canGoForward)
    }

    @Test
    func unavailableHistoryEntriesAreDiscarded() async {
        let navigation = MainWindowNavigation(openMainWindow: {})
        let availableMeetingId = UUID.v7()
        let unavailableMeetingId = UUID.v7()
        navigation.recordNavigation(to: .meeting(availableMeetingId))
        navigation.recordNavigation(to: .meeting(unavailableMeetingId))
        navigation.recordNavigation(to: .project(.v7()))

        await navigation.goBack(
            validatingWith: { location in
                location != .meeting(unavailableMeetingId)
            },
            restoringWith: { _ in }
        )

        #expect(navigation.currentLocation == .meeting(availableMeetingId))
    }

    @Test
    func unavailableEntryDoesNotPublishItsSectionOrChangeCurrentLocation() async {
        let navigation = MainWindowNavigation(openMainWindow: {})
        let missingProjectId = UUID.v7()
        let meetingId = UUID.v7()
        navigation.resetNavigationHistory(to: .project(missingProjectId))
        navigation.recordNavigation(to: .meeting(meetingId))
        var restoredLocation: MainWindowLocation?

        await navigation.goBack(
            validatingWith: { _ in
                #expect(navigation.section == .meetings)
                return false
            },
            restoringWith: { restoredLocation = $0 }
        )

        #expect(restoredLocation == nil)
        #expect(navigation.currentLocation == .meeting(meetingId))
        #expect(navigation.section == .meetings)
    }

    @Test
    func normalNavigationCancelsSuspendedHistoryWithoutDiscardingIt() async {
        let navigation = MainWindowNavigation(openMainWindow: {})
        let meetingId = UUID.v7()
        let projectId = UUID.v7()
        let gate = NavigationValidationGate()
        navigation.recordNavigation(to: .meeting(meetingId))
        navigation.recordNavigation(to: .project(projectId))

        let traversal = Task {
            await navigation.goBack(
                validatingWith: { _ in
                    await gate.wait()
                    return true
                },
                restoringWith: { _ in }
            )
        }
        while !navigation.isNavigatingHistory {
            await Task.yield()
        }

        navigation.recordNavigation(to: .unprocessedRecordings)
        await gate.release()
        await traversal.value

        #expect(navigation.currentLocation == .unprocessedRecordings)
        await navigateBack(navigation)
        #expect(navigation.currentLocation == .project(projectId))
    }

    @Test
    func resettingHistoryCancelsSuspendedNavigation() async {
        let navigation = MainWindowNavigation(openMainWindow: {})
        let gate = NavigationValidationGate()
        navigation.recordNavigation(to: .meeting(.v7()))

        let traversal = Task {
            await navigation.goBack(
                validatingWith: { _ in
                    await gate.wait()
                    return true
                },
                restoringWith: { _ in }
            )
        }
        while !navigation.isNavigatingHistory {
            await Task.yield()
        }

        navigation.resetNavigationHistory(to: .unprocessedRecordings)
        await gate.release()
        await traversal.value

        #expect(!navigation.isNavigatingHistory)
        #expect(navigation.currentLocation == .unprocessedRecordings)
        #expect(!navigation.canGoBack)
        #expect(!navigation.canGoForward)
    }

    @Test
    func historyRetainsOnlyTheMostRecentFiftyLocations() async {
        let navigation = MainWindowNavigation(openMainWindow: {})
        for _ in 0 ..< 51 {
            navigation.recordNavigation(to: .meeting(.v7()))
        }

        var restoredCount = 0
        while navigation.canGoBack {
            await navigation.goBack(
                validatingWith: { _ in true },
                restoringWith: { _ in restoredCount += 1 }
            )
        }

        #expect(restoredCount == 50)
    }

    @Test
    func openingProjectsSetsSectionBeforeOpeningMainWindow() {
        var observedSection: MainWindowSection?
        var navigation: MainWindowNavigation?
        let subject = MainWindowNavigation {
            observedSection = navigation?.section
        }
        navigation = subject
        subject.resetNavigationHistory(to: .project(.v7()))
        subject.showMeetings()

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
    func openingMeetingsWithoutActivationUsesTheNonactivatingPresenter() {
        var didOpenActivating = false
        var observedSection: MainWindowSection?
        var navigation: MainWindowNavigation?
        let subject = MainWindowNavigation(
            openMainWindow: { didOpenActivating = true },
            openMainWindowWithoutActivation: { observedSection = navigation?.section }
        )
        navigation = subject
        subject.showProjects()

        subject.openMeetingsWithoutActivation()

        #expect(!didOpenActivating)
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

    @Test
    func automaticProjectSelectionReplacesCurrentLocationWithoutAddingHistory() {
        let navigation = MainWindowNavigation(openMainWindow: {})
        let vaultId = UUID.v7()
        let first = project(named: "First")
        navigation.resetNavigationHistory(to: .project(nil))

        navigation.reconcileProjectCatalog(vaultId: vaultId, projects: [first])

        #expect(navigation.selectedProjectId == first.projectId)
        #expect(navigation.currentLocation == .project(first.projectId))
        #expect(!navigation.canGoBack)
    }

    private func navigateBack(_ navigation: MainWindowNavigation) async {
        await navigation.goBack(
            validatingWith: { _ in true },
            restoringWith: { _ in }
        )
    }

    private func navigateForward(_ navigation: MainWindowNavigation) async {
        await navigation.goForward(
            validatingWith: { _ in true },
            restoringWith: { _ in }
        )
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

extension MainWindowNavigationTests {
    @Test
    func deletingSelectedProjectRemovesRedundantAndUnavailableHistory() {
        let navigation = MainWindowNavigation(openMainWindow: {})
        let vaultId = UUID.v7()
        let first = project(named: "First")
        let selected = project(named: "Selected")
        let unavailable = project(named: "Unavailable")
        navigation.resetNavigationHistory(to: .project(first.projectId))
        navigation.recordNavigation(to: .project(unavailable.projectId))
        navigation.recordNavigation(to: .project(selected.projectId))
        navigation.selectedProjectId = selected.projectId

        navigation.reconcileProjectCatalog(vaultId: vaultId, projects: [first])

        #expect(navigation.currentLocation == .project(first.projectId))
        #expect(!navigation.canGoBack)
        #expect(!navigation.canGoForward)
    }
}

private actor NavigationValidationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        if isReleased { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}
#endif
