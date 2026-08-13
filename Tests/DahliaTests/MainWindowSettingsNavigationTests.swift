#if canImport(Testing)
import Foundation
import Testing
@testable import Dahlia

@MainActor
struct MainWindowSettingsNavigationTests {
    @Test
    func settingsPresentationPreservesCurrentAppLocation() {
        let projectId = UUID.v7()
        let navigation = MainWindowNavigation(
            openMainWindow: {},
            initialSettingsCategory: .general
        )
        navigation.recordNavigation(to: .project(projectId))

        navigation.openSettings(category: .calendar)

        #expect(navigation.isShowingSettings)
        #expect(navigation.settingsCategory == .calendar)
        #expect(navigation.section == .projects)
        #expect(navigation.currentLocation == .project(projectId))

        navigation.dismissSettings()

        #expect(!navigation.isShowingSettings)
        #expect(navigation.section == .projects)
        #expect(navigation.currentLocation == .project(projectId))
    }

    @Test
    func openingSettingsPublishesPresentationBeforeOpeningMainWindow() {
        var observedPresentation = false
        var navigation: MainWindowNavigation?
        let subject = MainWindowNavigation(
            openMainWindow: { observedPresentation = navigation?.isShowingSettings == true },
            initialSettingsCategory: .general
        )
        navigation = subject

        subject.openSettings()

        #expect(observedPresentation)
    }

    @Test
    func openingVaultSettingsPreservesCurrentAppLocation() {
        let meetingID = UUID.v7()
        let navigation = MainWindowNavigation(
            openMainWindow: {},
            initialSettingsCategory: .general
        )
        navigation.recordNavigation(to: .meeting(meetingID))

        navigation.openSettings(category: .vault)

        #expect(navigation.isShowingSettings)
        #expect(navigation.settingsCategory == .vault)
        #expect(navigation.currentLocation == .meeting(meetingID))
    }

    @Test
    func explicitMainDestinationDismissesSettings() {
        let navigation = MainWindowNavigation(
            openMainWindow: {},
            initialSettingsCategory: .general
        )
        navigation.openSettings()

        navigation.openProjects()

        #expect(!navigation.isShowingSettings)
        #expect(navigation.section == .projects)
    }

    @Test
    func changingVaultWhileSettingsAreVisibleResetsThePreservedLocation() {
        let navigation = MainWindowNavigation(
            openMainWindow: {},
            initialSettingsCategory: .general
        )
        navigation.recordNavigation(to: .meeting(UUID.v7()))
        navigation.openSettings()

        navigation.changeVault(to: UUID.v7())
        navigation.dismissSettings()

        #expect(navigation.currentLocation == .upcomingSchedule)
        #expect(navigation.section == .meetings)
        #expect(!navigation.canGoBack)
        #expect(!navigation.canGoForward)
    }
}
#endif
