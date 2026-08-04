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
    }
#endif
