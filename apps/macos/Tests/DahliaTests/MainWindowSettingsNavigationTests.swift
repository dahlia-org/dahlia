#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    @MainActor
    struct MainWindowSettingsNavigationTests {
        @Test
        func meetingsStartWithProcessingFlowAndKeepItWhenReturningFromWorkspaceSettings() throws {
            let suite = "MainWindowSettingsNavigationTests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let navigation = MainWindowNavigation(openMainWindow: {}, initialSettingsCategory: .general, settingsDefaults: defaults)
            navigation.openSettings(category: .meetings)
            navigation.meetingProcessingSelection = .workspace

            navigation.openSettings(category: .workspace)
            #expect(navigation.settingsCategory == .workspace)
            navigation.openSettings(category: .meetings)
            #expect(navigation.settingsCategory == .meetings)
            #expect(navigation.meetingProcessingSelection == .workspace)
        }

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
        func appIntegrationsOpensMCPSettingsAndPreservesChat() throws {
            let suite = "MainWindowSettingsNavigationTests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            var observedTab: AgentSettingsView.Tab?
            var observedCategory: SettingsCategory?
            var navigation: MainWindowNavigation?
            let subject = MainWindowNavigation(
                openMainWindow: {
                    observedTab = navigation?.agentSettingsTab
                    observedCategory = navigation?.settingsCategory
                },
                initialSettingsCategory: .general,
                settingsDefaults: defaults
            )
            navigation = subject
            subject.recordNavigation(to: .chat)
            subject.agentSettingsTab = .models

            subject.openAgentSettings(tab: .mcps)

            #expect(subject.isShowingSettings)
            #expect(observedTab == .mcps)
            #expect(observedCategory == .agents)
            #expect(subject.currentLocation == .chat)

            subject.dismissSettings()

            #expect(!subject.isShowingSettings)
            #expect(subject.currentLocation == .chat)
        }

        @Test
        func eventDisplayLinkOpensCalendarOnItsTab() {
            let navigation = MainWindowNavigation(openMainWindow: {}, initialSettingsCategory: .general)
            #expect(navigation.calendarTab == .sources)

            navigation.openSettings(category: .eventDisplay)

            #expect(navigation.settingsCategory == .calendar)
            #expect(navigation.calendarTab == .eventDisplay)
            #expect(navigation.appearanceTab == .general)

            navigation.openSettings()
            #expect(navigation.calendarTab == .eventDisplay)

            navigation.openSettings(category: .calendar)
            #expect(navigation.settingsCategory == .calendar)
            #expect(navigation.calendarTab == .sources)
        }

        @Test(arguments: [SettingsCategory.accountsAndWorkspaces, .accountPreferences, .aiSummary])
        func inferenceAndMCPLinksOpenDahliaAITabs(category: SettingsCategory) {
            let navigation = MainWindowNavigation(openMainWindow: {}, initialSettingsCategory: .general)
            navigation.openSettings(category: category)
            #expect(navigation.settingsCategory == .agents)
            #expect(navigation.agentSettingsTab == .models)

            navigation.openSettings(category: .mcp)
            #expect(navigation.settingsCategory == .agents)
            #expect(navigation.agentSettingsTab == .mcps)

            navigation.openSettings(category: .aiSummary)
            #expect(navigation.agentSettingsTab == .models)

            navigation.agentSettingsTab = .schedules
            navigation.openSettings()
            #expect(navigation.agentSettingsTab == .schedules)
        }

        @Test
        func formerRecordingPagesSelectTheirProcessingStep() {
            let navigation = MainWindowNavigation(openMainWindow: {}, initialSettingsCategory: .general)
            navigation.openSettings(category: .screenshots)
            #expect(navigation.settingsCategory == .meetings)
            #expect(navigation.meetingProcessingSelection == .screenshots)

            navigation.openSettings(category: .liveSubtitles)
            #expect(navigation.meetingProcessingSelection == .liveTranscription)

            navigation.openSettings(category: .recordingStopDetection)
            #expect(navigation.meetingProcessingSelection == .transcription)

            navigation.openSettings(category: .meetingLinks)
            navigation.openSettings(category: .transcription)
            #expect(navigation.meetingProcessingSelection == .transcription)

            navigation.openSettings(category: .meetingLinks)
            #expect(navigation.settingsCategory == .meetingLinks)
        }

        @Test(arguments: [SettingsCategory.agents, .macInference, .dahliaAccounts])
        func setupLinksOpenGeneralFromEveryAITab(category: SettingsCategory) {
            let navigation = MainWindowNavigation(openMainWindow: {}, initialSettingsCategory: .general)
            for previousTab in AgentSettingsView.Tab.allCases {
                navigation.agentSettingsTab = previousTab
                navigation.openSettings(category: category)
                #expect(navigation.settingsCategory == .agents)
                #expect(navigation.agentSettingsTab == .general)
            }
        }

        @Test
        func providerSetupOpensModelsFromEveryAITab() {
            let navigation = MainWindowNavigation(openMainWindow: {}, initialSettingsCategory: .general)
            for previousTab in AgentSettingsView.Tab.allCases {
                navigation.agentSettingsTab = previousTab
                navigation.openSettings(category: .modelProvider)
                #expect(navigation.settingsCategory == .agents)
                #expect(navigation.agentSettingsTab == .models)
            }
            #expect(AgentSettingsView.Tab.allCases == [.general, .models, .mcps, .schedules, .packages, .security])
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
        func openingDahliaSignInPreservesTheCurrentScreen() {
            let navigation = MainWindowNavigation(
                openMainWindow: {},
                initialSettingsCategory: .calendar
            )

            navigation.openDahliaSignIn()

            #expect(!navigation.isShowingSettings)
            #expect(navigation.settingsCategory == .calendar)
            #expect(navigation.isShowingDahliaSignIn)

            navigation.dismissDahliaSignIn()

            #expect(!navigation.isShowingDahliaSignIn)
        }

        @Test
        func openingWorkspaceSettingsPreservesCurrentAppLocation() {
            let meetingID = UUID.v7()
            let navigation = MainWindowNavigation(
                openMainWindow: {},
                initialSettingsCategory: .general
            )
            navigation.recordNavigation(to: .meeting(meetingID))

            navigation.openSettings(category: .workspace)

            #expect(navigation.isShowingSettings)
            #expect(navigation.settingsCategory == .workspace)
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

            navigation.openUnprocessedRecordings()

            #expect(!navigation.isShowingSettings)
            #expect(navigation.section == .meetings)
            #expect(navigation.currentLocation == .unprocessedRecordings)
        }

        @Test
        func changingWorkspaceWhileSettingsAreVisibleResetsThePreservedLocation() {
            let navigation = MainWindowNavigation(
                openMainWindow: {},
                initialSettingsCategory: .general
            )
            navigation.recordNavigation(to: .meeting(UUID.v7()))
            navigation.openSettings()

            navigation.changeWorkspace(to: UUID.v7())
            navigation.dismissSettings()

            #expect(navigation.currentLocation == .upcomingSchedule)
            #expect(navigation.section == .meetings)
            #expect(!navigation.canGoBack)
            #expect(!navigation.canGoForward)
        }
    }
#endif
