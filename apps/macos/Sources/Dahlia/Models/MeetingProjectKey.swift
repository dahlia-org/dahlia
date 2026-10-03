import Foundation

enum MeetingProjectKey: Hashable, Sendable {
    case project(UUID)
    case unassigned

    var projectId: UUID? {
        switch self {
        case let .project(id): id
        case .unassigned: nil
        }
    }
}
