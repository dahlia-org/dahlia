#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    @MainActor
    struct MainWindowSettingsNavigationTests {
        @Test
        func settingsPresentationPreservesCurrentAppLocation() {
            let navigation = MainWindowNavigation(
                openMainWindow: {},
                initialSettingsCategory: .general
            )
            navigation.recordNavigation(to: .projects)

            navigation.openSettings(category: .calendar)

            #expect(navigation.isShowingSettings)
            #expect(navigation.settingsCategory == .calendar)
            #expect(navigation.section == .projects)
            #expect(navigation.currentLocation == .projects)

            navigation.dismissSettings()

            #expect(!navigation.isShowingSettings)
            #expect(navigation.section == .projects)
            #expect(navigation.currentLocation == .projects)
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
        func openingUnprocessedRecordingsFromSettingsSelectsDestinationAndDismissesSettings() {
            let navigation = MainWindowNavigation(
                openMainWindow: {},
                initialSettingsCategory: .backups
            )
            navigation.recordNavigation(to: .projects)
            navigation.openSettings()

            navigation.openUnprocessedRecordingsFromSettings()

            #expect(!navigation.isShowingSettings)
            #expect(navigation.section == .meetings)
            #expect(navigation.currentLocation == .unprocessedRecordings)
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
