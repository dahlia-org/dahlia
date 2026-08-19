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
        func persistsSidebarModeAndVaultScopedPinOrder() throws {
            let suiteName = "MainWindowNavigationTests-\(UUID.v7())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let firstVault = UUID.v7()
            let secondVault = UUID.v7()
            let firstProject = UUID.v7()
            let secondProject = UUID.v7()
            let navigation = MainWindowNavigation(openMainWindow: {}, settingsDefaults: defaults)

            navigation.meetingSidebarDisplayMode = .byProject
            navigation.toggleProjectPin(firstProject, vaultId: firstVault)
            navigation.toggleProjectPin(secondProject, vaultId: firstVault)
            navigation.toggleProjectPin(firstProject, vaultId: secondVault)

            let restored = MainWindowNavigation(openMainWindow: {}, settingsDefaults: defaults)
            #expect(restored.meetingSidebarDisplayMode == .byProject)
            #expect(restored.pinnedProjectIDs(vaultId: firstVault) == [secondProject, firstProject])
            #expect(restored.pinnedProjectIDs(vaultId: secondVault) == [firstProject])
        }

        @Test
        func persistsVaultScopedProjectAppearancesAndDefaultsInvalidValues() throws {
            let suiteName = "MainWindowNavigationTests-\(UUID.v7())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let firstVault = UUID.v7()
            let secondVault = UUID.v7()
            let project = UUID.v7()
            let validProject = UUID.v7()
            let appearance = ProjectAppearance(icon: .music, color: .purple)
            let navigation = MainWindowNavigation(openMainWindow: {}, settingsDefaults: defaults)

            #expect(navigation.projectAppearance(projectId: project, vaultId: firstVault) == .default)
            navigation.setProjectAppearance(appearance, projectId: project, vaultId: firstVault)

            let restored = MainWindowNavigation(openMainWindow: {}, settingsDefaults: defaults)
            #expect(restored.projectAppearance(projectId: project, vaultId: firstVault) == appearance)
            #expect(restored.projectAppearance(projectId: project, vaultId: secondVault) == .default)

            defaults.set(
                Data(
                    #"{"\#(firstVault.uuidString)":{"\#(project.uuidString)":{"icon":"unknown","color":"blue"},"\#(validProject.uuidString)":{"icon":"music.note","color":"purple"}}}"#
                        .utf8
                ),
                forKey: "projectAppearances"
            )
            let invalidRestored = MainWindowNavigation(openMainWindow: {}, settingsDefaults: defaults)
            #expect(invalidRestored.projectAppearance(projectId: project, vaultId: firstVault) == .default)
            #expect(invalidRestored.projectAppearance(projectId: validProject, vaultId: firstVault) == appearance)
        }

        @Test
        func persistsVaultScopedProjectDetailDisplayMode() throws {
            let suiteName = "MainWindowNavigationTests-\(UUID.v7())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let firstVault = UUID.v7()
            let secondVault = UUID.v7()
            let navigation = MainWindowNavigation(openMainWindow: {}, settingsDefaults: defaults)

            #expect(navigation.projectDetailDisplayMode(vaultId: firstVault) == .list)
            navigation.setProjectDetailDisplayMode(.calendar, vaultId: firstVault)

            let restored = MainWindowNavigation(openMainWindow: {}, settingsDefaults: defaults)
            #expect(restored.projectDetailDisplayMode(vaultId: firstVault) == .calendar)
            #expect(restored.projectDetailDisplayMode(vaultId: secondVault) == .list)
        }

    }

    extension MainWindowNavigationTests {
        @Test
        func navigatesBackwardAndForwardThroughMainLocations() async {
            let navigation = MainWindowNavigation(openMainWindow: {})
            let meetingId = UUID.v7()
            navigation.recordNavigation(to: .meeting(meetingId))
            navigation.recordNavigation(to: .projects)
            navigation.recordNavigation(to: .unprocessedRecordings)

            await navigateBack(navigation)
            #expect(navigation.currentLocation == .projects)
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
        func navigatesBetweenProjectCatalogAndProjectDetail() async {
            let navigation = MainWindowNavigation(openMainWindow: {})
            let projectID = UUID.v7()
            navigation.recordNavigation(to: .projects)
            navigation.recordNavigation(to: .project(projectID))

            await navigateBack(navigation)
            #expect(navigation.currentLocation == .projects)

            await navigateForward(navigation)
            #expect(navigation.currentLocation == .project(projectID))
            #expect(navigation.section == .projects)
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
            navigation.recordNavigation(to: .projects)
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
            navigation.recordNavigation(to: .projects)

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
            navigation.recordNavigation(to: .projects)
            navigation.recordNavigation(to: .unprocessedRecordings)
            await navigateBack(navigation)

            navigation.changeVault(to: vaultId)

            #expect(navigation.currentLocation == .projects)
            #expect(!navigation.canGoBack)
            #expect(!navigation.canGoForward)
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
            navigation.recordNavigation(to: .projects)

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
            let meetingId = UUID.v7()
            navigation.resetNavigationHistory(to: .projects)
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
            let gate = NavigationValidationGate()
            navigation.recordNavigation(to: .meeting(meetingId))
            navigation.recordNavigation(to: .projects)

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
            #expect(navigation.currentLocation == .projects)
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
            subject.resetNavigationHistory(to: .projects)
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

    }

    extension MainWindowNavigationTests {
        @Test
        func clearingMeetingSelectionRecordsVisibleUpcomingSchedule() async {
            let navigation = MainWindowNavigation(openMainWindow: {})
            let meetingId = UUID.v7()
            navigation.recordNavigation(to: .meeting(meetingId))

            navigation.recordUpcomingScheduleIfVisible(true)

            #expect(navigation.currentLocation == .upcomingSchedule)
            await navigateBack(navigation)
            #expect(navigation.currentLocation == .meeting(meetingId))
        }

        @Test
        func programmaticSelectionClearKeepsRecordedDestination() {
            let navigation = MainWindowNavigation(openMainWindow: {})
            navigation.recordNavigation(to: .meeting(.v7()))
            navigation.recordNavigation(to: .unprocessedRecordings)

            navigation.recordUpcomingScheduleIfVisible(true)

            #expect(navigation.currentLocation == .unprocessedRecordings)
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
