import DahliaRuntimeSupport
import Foundation
import GRDB

struct CodexChatScopeSnapshot: Equatable, Sendable {
    let projects: [ProjectRecord]
    let projectID: UUID?
    var projectDisplayNames: [UUID: String] = [:]

    func displayName(for project: ProjectRecord) -> String {
        projectDisplayNames[project.id] ?? project.path
    }

    static func fetch(
        accountID: String,
        threadID: String?,
        context: CodexChatContext?,
        in db: Database
    ) throws -> Self {
        let projectID: UUID?
        if let threadID {
            let thread = try ChatThreadRecord.fetchOne(db, key: threadID)
            guard thread?.accountID == accountID else { throw PiRuntimeError.invalidProtocolResponse }
            projectID = thread?.projectID
        } else {
            projectID = switch context {
            case let .project(id, _, _): id
            case let .meeting(id, _, _): try MeetingRecord.fetchOne(db, key: id)?.projectId
            default: nil
            }
        }
        let workspaces = try WorkspaceRecord.fetchAll(db).filter { CodexRuntimeProvider(workspace: $0).accountKey == accountID }
        let projects = try workspaces.flatMap { try ProjectRecord.fetchResolvedAll(workspaceId: $0.id, in: db) }
        let projectsByPath = Dictionary(grouping: projects, by: \.path)
        let workspacesByName = Dictionary(grouping: workspaces, by: \.name)
        let workspaceNames = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0.name) })
        let displayNames = Dictionary(uniqueKeysWithValues: projects.map { project in
            guard projectsByPath[project.path, default: []].count > 1,
                  let workspaceName = workspaceNames[project.workspaceId] else { return (project.id, project.path) }
            let qualifier = workspacesByName[workspaceName, default: []].count > 1
                ? "\(workspaceName) · \(TypeID.encode(project.workspaceId, as: .workspace))"
                : workspaceName
            return (project.id, "\(project.path) (\(qualifier))")
        })
        return Self(
            projects: projects,
            projectID: projects.contains { $0.id == projectID } ? projectID : nil,
            projectDisplayNames: displayNames
        )
    }
}
