import Foundation
import GRDB

enum DocumentPublication {
    struct Candidate: Identifiable, Sendable {
        let id: UUID
        let meetingID: UUID
        let name: String
        let text: String
        let checkpoint: String
    }

    static func candidates(workspaceID: UUID, dbQueue: DatabaseQueue) async throws -> [Candidate] {
        let source = try await dbQueue.read { db in
            try MeetingRecord.filter(Column("workspace_id") == workspaceID).order(Column("createdAt")).fetchAll(db)
        }
        let persistence = DocumentPersistence(dbQueue: dbQueue)
        var result: [Candidate] = []
        for meeting in source {
            let existing = try await dbQueue.read { db -> (Bool, DocumentPrivateCopyRecord?, MeetingNoteRecord?) in
                let published = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM document_legacy_imports WHERE meetingId = ?)",
                    arguments: [meeting.id]
                ) ?? false
                return try (
                    published,
                    DocumentPrivateCopyRecord.filter(Column("meetingId") == meeting.id).filter(Column("kind") == "notes")
                        .order(Column("updatedAt").desc).fetchOne(db),
                    MeetingNoteRecord.fetchOne(db, key: meeting.id)
                )
            }
            guard !existing.0 else { continue }
            var copy = existing.1
            if copy == nil, let note = existing.2, !note.text.isEmpty {
                let checkpoint = try await persistence.legacyImport(text: note.text)
                let prepared = DocumentPrivateCopyRecord(
                    id: .v7(),
                    workspaceId: meeting.workspaceId,
                    meetingId: meeting.id,
                    checkpoint: checkpoint,
                    text: note.text,
                    createdAt: note.createdAt,
                    updatedAt: note.updatedAt
                )
                try await dbQueue.write { try prepared.insert($0) }
                copy = prepared
            }
            if let copy { result.append(Candidate(
                id: copy.id,
                meetingID: meeting.id,
                name: meeting.name,
                text: copy.text,
                checkpoint: copy.checkpoint
            )) }
        }
        return result
    }

    static func publish(_ candidates: [Candidate], workspaceID: UUID, connectionID: UUID, dbQueue: DatabaseQueue) async throws -> [String] {
        let client = SyncAPIClient(session: .shared)
        let sync = DocumentSyncService.shared(dbQueue: dbQueue, api: client)
        var conflicts: [String] = []
        for candidate in candidates {
            guard let target = try await sync.target(meetingID: candidate.meetingID), target.workspaceID == workspaceID,
                  target.connectionID == connectionID else { throw DocumentCoreError.unavailable }
            do {
                let workspaceID = workspaceID.uuidString.lowercased(), meetingID = candidate.meetingID.uuidString.lowercased()
                _ = try await client.data(origin: target.origin, connectionId: target.connectionID, maximumBytes: DocumentLimits.responseBytes) {
                    try await $0.initializeMeetingNotes(
                        path: .init(workspaceId: workspaceID, meetingId: meetingID),
                        body: .json(.init(id: UUID.v7().uuidString.lowercased(), legacyUpdate: candidate.checkpoint))
                    ).ok.body.json
                }
                try await sync.synchronize(meetingID: candidate.meetingID)
                try await dbQueue.write { db in
                    try target.validate(in: db)
                    try db.execute(sql: "INSERT OR REPLACE INTO document_legacy_imports VALUES (?, ?)", arguments: [candidate.meetingID, Date()])
                }
            } catch let error as SyncHTTPError where error.status == 409 {
                conflicts.append(candidate.name)
            }
        }
        return conflicts
    }
}
