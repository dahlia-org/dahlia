import DahliaMeetingAccess
import DahliaRuntimeSupport
import Foundation
import GRDB

extension MeetingContentProvider {
    func resolve(_ request: TextBrokerRequest, workspaceId: UUID, dbQueue: DatabaseQueue) async throws -> Data {
        let store = MeetingAccessStore(database: dbQueue, workspaceID: workspaceId)
        if request.operation == .search {
            guard let query = request.query, let kind = request.kind else { throw TextContentError.unavailable }
            return try await JSONEncoder().encode(search(
                workspaceId: workspaceId,
                query: query,
                kind: kind,
                cursor: request.cursor,
                limit: request.limit,
                dbQueue: dbQueue
            ))
        }
        guard let meetingId = request.meetingId,
              try await dbQueue.read({ db in
                  try Bool
                      .fetchOne(
                          db,
                          sql: "SELECT EXISTS(SELECT 1 FROM meetings WHERE id = ? AND workspace_id = ?)",
                          arguments: [meetingId, workspaceId]
                      ) ==
                      true
              }) else { throw TextContentError.deleted }
        if request.operation == .touch {
            guard let entity = request.entity, entity != .file else { throw TextContentError.unavailable }
            try await touch(entity: entity, id: meetingId, dbQueue: dbQueue)
            return Data("{}".utf8)
        }
        let entities: Set<TextContentEntity> = request.operation == .meeting ? [.summary] : [.transcript]
        return try await withContent(meetingId: meetingId, entities: entities, dbQueue: dbQueue) {
            switch request.operation {
            case .meeting: return try JSONEncoder().encode(store.meeting(id: meetingId))
            case .transcript:
                return try JSONEncoder().encode(store.transcript(
                    meetingID: meetingId,
                    fromElapsedSeconds: request.fromElapsedSeconds,
                    toElapsedSeconds: request.toElapsedSeconds,
                    limit: request.limit,
                    cursor: request.cursor
                ))
            case .search, .touch: throw TextContentError.unavailable
            }
        }
    }
}
