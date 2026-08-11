import Foundation

struct ProjectRevisionObservationTracker: Equatable {
    private var revisionsByProjectId: [UUID: Set<Int>] = [:]

    mutating func record(projectId: UUID, revision: Int) {
        revisionsByProjectId[projectId, default: []].insert(revision)
    }

    mutating func consume(projectId: UUID, revision: Int) -> Bool {
        guard let revisions = revisionsByProjectId[projectId],
              revisions.contains(revision) else {
            return false
        }
        let remaining = revisions.filter { $0 > revision }
        revisionsByProjectId[projectId] = remaining.isEmpty ? nil : remaining
        return true
    }

    mutating func discard(projectId: UUID) {
        revisionsByProjectId[projectId] = nil
    }
}
