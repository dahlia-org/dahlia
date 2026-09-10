import DahliaMeetingAccess
import DahliaRuntimeSupport
import Foundation
import GRDB

extension MeetingContentProvider {
    func resolve(_ request: TextBrokerRequest, vaultId: UUID, dbQueue: DatabaseQueue) async throws -> Data {
        let store = MeetingAccessStore(database: dbQueue, vaultID: vaultId)
        if request.operation == .liveMeetings {
            guard try await dbQueue
                .read({ db in try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM vaults WHERE id = ?)", arguments: [vaultId]) == true }) else {
                throw LiveTranscriptError.notFound
            }
            return try JSONEncoder().encode(LiveTranscriptStore.shared.list(vaultID: vaultId, database: dbQueue))
        }
        if request.operation == .liveTranscript {
            guard let meetingID = request.meetingId else { throw LiveTranscriptError.invalidRequest }
            return try await JSONEncoder().encode(LiveTranscriptStore.shared.read(
                vaultID: vaultId,
                meetingID: meetingID,
                cursor: request.cursor,
                limit: request.limit,
                database: dbQueue
            ))
        }
        if request.operation == .search {
            guard let query = request.query, let kind = request.kind else { throw TextContentError.unavailable }
            return try await JSONEncoder().encode(search(
                vaultId: vaultId,
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
                      .fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM meetings WHERE id = ? AND vaultId = ?)", arguments: [meetingId, vaultId]) ==
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
            case .search, .touch, .liveMeetings, .liveTranscript: throw TextContentError.unavailable
            }
        }
    }
}
