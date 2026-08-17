import Foundation

enum ProjectNavigationIntent: Equatable, Sendable {
    case open
    case edit
    case delete
}

struct PendingProjectNavigationIntent: Equatable, Sendable {
    let projectId: UUID
    let intent: ProjectNavigationIntent
}
