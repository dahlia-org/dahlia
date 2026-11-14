import Foundation
import GRDB

struct CodexChatScopeSnapshot: Equatable, Sendable {
    let projects: [ProjectRecord]
    let projectID: UUID?

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
        return Self(projects: projects, projectID: projects.contains { $0.id == projectID } ? projectID : nil)
    }
}
