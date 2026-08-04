import Foundation

enum MainNavigationRoute: Hashable {
    case schedule
    case meetings
    case project(UUID)
    case organizations

    var projectID: UUID? {
        guard case let .project(id) = self else { return nil }
        return id
    }

    var showsMeetingList: Bool {
        switch self {
        case .meetings, .project: true
        case .schedule, .organizations: false
        }
    }
}

struct MainNavigationState: Equatable {
    var route: MainNavigationRoute = .meetings
    var meetingSelection: Set<UUID> = []

    mutating func select(_ route: MainNavigationRoute) {
        self.route = route
        if !route.showsMeetingList {
            meetingSelection.removeAll()
        }
    }

    mutating func selectMeetings(_ selection: Set<UUID>) {
        meetingSelection = selection
        if !selection.isEmpty, !route.showsMeetingList {
            route = .meetings
        }
    }

    mutating func reconcileSelectedMeetingProject(_ projectID: UUID?) {
        guard let scopeProjectID = route.projectID, scopeProjectID != projectID else { return }
        route = .meetings
    }

    mutating func reconcileOrganizationsAvailability(_ isAvailable: Bool) {
        if !isAvailable, route == .organizations {
            route = .meetings
        }
    }

    mutating func resetForVaultChange() {
        self = Self()
    }
}
