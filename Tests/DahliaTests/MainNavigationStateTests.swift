import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct MainNavigationStateTests {
        @Test
        func projectSelectionKeepsMeetingSelectionAndExposesScope() {
            let projectID = UUID()
            let meetingID = UUID()
            var state = MainNavigationState(route: .meetings, meetingSelection: [meetingID])

            state.select(.project(projectID))

            #expect(state.route.projectID == projectID)
            #expect(state.meetingSelection == [meetingID])
        }

        @Test(arguments: [MainNavigationRoute.schedule, .organizations])
        func nonMeetingSectionsClearMeetingSelection(route: MainNavigationRoute) {
            var state = MainNavigationState(route: .meetings, meetingSelection: [UUID(), UUID()])

            state.select(route)

            #expect(state.meetingSelection.isEmpty)
        }

        @Test
        func vaultChangeReturnsToAllMeetings() {
            var state = MainNavigationState(route: .project(UUID()), meetingSelection: [UUID()])

            state.resetForVaultChange()

            #expect(state.route == .meetings)
            #expect(state.meetingSelection.isEmpty)
        }

        @Test(arguments: [MainNavigationRoute.schedule, .organizations])
        func selectingAMeetingFromAnotherSectionReturnsToMeetings(route: MainNavigationRoute) {
            let meetingID = UUID()
            var state = MainNavigationState(route: route)

            state.selectMeetings([meetingID])

            #expect(state.route == .meetings)
            #expect(state.meetingSelection == [meetingID])
        }

        @Test
        func selectingAMeetingOutsideTheProjectScopeReturnsToAllMeetings() {
            let scopeProjectID = UUID()
            var state = MainNavigationState(route: .project(scopeProjectID))

            state.reconcileSelectedMeetingProject(UUID())

            #expect(state.route == .meetings)
        }

        @Test
        func disablingOrganizationsWhileItIsSelectedReturnsToMeetings() {
            var state = MainNavigationState(route: .organizations)

            state.reconcileOrganizationsAvailability(false)

            #expect(state.route == .meetings)
        }

        @Test
        func backAndForwardRestoreRoutesAndMeetingSelections() {
            let firstMeetingID = UUID()
            let secondMeetingID = UUID()
            var state = MainNavigationState(route: .meetings, meetingSelection: [firstMeetingID])

            state.select(.schedule)
            state.selectMeetings([secondMeetingID])

            #expect(state.canGoBack)
            #expect(!state.canGoForward)

            let returnedToSchedule = state.goBack()
            #expect(returnedToSchedule)
            #expect(state.route == .schedule)
            #expect(state.meetingSelection.isEmpty)

            let returnedToFirstMeeting = state.goBack()
            #expect(returnedToFirstMeeting)
            #expect(state.route == .meetings)
            #expect(state.meetingSelection == [firstMeetingID])
            #expect(!state.canGoBack)

            let advancedToSchedule = state.goForward()
            #expect(advancedToSchedule)
            #expect(state.route == .schedule)
            #expect(state.canGoForward)
        }

        @Test
        func newNavigationClearsForwardHistory() {
            var state = MainNavigationState()

            state.select(.schedule)
            let didGoBack = state.goBack()
            #expect(didGoBack)
            #expect(state.canGoForward)

            state.select(.project(UUID()))

            #expect(!state.canGoForward)
        }

        @Test
        func vaultChangeClearsNavigationHistory() {
            var state = MainNavigationState()
            state.select(.schedule)

            state.resetForVaultChange()

            #expect(!state.canGoBack)
            #expect(!state.canGoForward)
        }

        @Test
        func disablingOrganizationsRemovesItFromHistory() {
            var state = MainNavigationState()
            state.select(.organizations)
            state.select(.schedule)

            state.reconcileOrganizationsAvailability(false)
            let didGoBack = state.goBack()
            #expect(didGoBack)

            #expect(state.route == .meetings)
            #expect(!state.canGoBack)
        }
    }
#endif
