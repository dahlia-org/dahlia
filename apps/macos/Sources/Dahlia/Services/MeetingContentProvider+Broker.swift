import DahliaMeetingAccess
import DahliaRuntimeSupport
import Foundation
import GRDB

extension MeetingContentProvider {
    func resolve(_ request: TextBrokerRequest, workspaceId: UUID, dbQueue: any DatabaseWriter) async throws -> Data {
        let store = MeetingAccessStore(database: dbQueue, workspaceID: workspaceId)
        // Searching a Dahlia Server's copy is gone with Desktop sync; the helper searches this Mac's index itself.
        guard request.operation != .search else { throw TextContentError.unavailable }
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
            guard let entity = request.entity else { throw TextContentError.unavailable }
            if entity == .file {
                guard let fileId = request.fileId else { throw TextContentError.unavailable }
                try await ScreenshotContentProvider.shared.touch(fileId: fileId, meetingId: meetingId, workspaceId: workspaceId, dbQueue: dbQueue)
            }
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
