import CryptoKit
import Foundation
import GRDB

struct SearchDocumentProjection {
    let kind: String
    let sourceID: UUID
    let vaultID: UUID
    let meetingID: UUID?
    let projectID: UUID?
    let segmentStart: Date?
    let segmentEnd: Date?
    let fields: SearchDocumentFields
}

struct SearchDocumentFields {
    let title: String
    let description: String
    let calendar: String
    let tags: String
    let projectPath: String
    let transcript: String

    static func transcript(_ text: String) -> Self {
        Self(title: "", description: "", calendar: "", tags: "", projectPath: "", transcript: text)
    }

    var hash: String {
        let content = [title, description, calendar, tags, projectPath, transcript]
            .map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

func upsertDocument(
    _ document: SearchDocumentProjection,
    generation: Int,
    forceFTSUpdate: Bool = false,
    in db: Database
) throws {
    let hash = document.fields.hash
    if let existing = try Row.fetchOne(
        db,
        sql: """
        SELECT id, sourceContentHash,
               EXISTS(SELECT 1 FROM search_documents_fts WHERE rowid = search_documents.id) AS hasFTS
        FROM search_documents WHERE kind = ? AND sourceId = ?
        """,
        arguments: [document.kind, document.sourceID]
    ) {
        let id: Int64 = existing["id"]
        let existingHash: String = existing["sourceContentHash"]
        let hasFTS: Bool = existing["hasFTS"]
        try updateRegistry(document, rowID: id, hash: hash, generation: generation, in: db)
        guard forceFTSUpdate || existingHash != hash || !hasFTS else { return }
        if hasFTS {
            try updateFTS(rowID: id, fields: document.fields, in: db)
        } else {
            try insertFTS(rowID: id, fields: document.fields, in: db)
        }
        return
    }
    try insertRegistry(document, hash: hash, generation: generation, in: db)
    try insertFTS(rowID: db.lastInsertedRowID, fields: document.fields, in: db)
}

private func updateRegistry(
    _ document: SearchDocumentProjection,
    rowID: Int64,
    hash: String,
    generation: Int,
    in db: Database
) throws {
    try db.execute(
        sql: """
        UPDATE search_documents SET vaultId = ?, meetingId = ?, projectId = ?,
            segmentStart = ?, segmentEnd = ?, sourceContentHash = ?, indexGeneration = ?, updatedAt = ?
        WHERE id = ?
        """,
        arguments: [
            document.vaultID,
            document.meetingID,
            document.projectID,
            document.segmentStart,
            document.segmentEnd,
            hash,
            generation,
            Date(),
            rowID,
        ]
    )
}

private func insertRegistry(
    _ document: SearchDocumentProjection,
    hash: String,
    generation: Int,
    in db: Database
) throws {
    try db.execute(
        sql: """
        INSERT INTO search_documents(
            kind, sourceId, vaultId, meetingId, projectId,
            segmentStart, segmentEnd, sourceContentHash, indexGeneration, updatedAt
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        arguments: [
            document.kind,
            document.sourceID,
            document.vaultID,
            document.meetingID,
            document.projectID,
            document.segmentStart,
            document.segmentEnd,
            hash,
            generation,
            Date(),
        ]
    )
}

private func insertFTS(rowID: Int64, fields: SearchDocumentFields, in db: Database) throws {
    try db.execute(
        sql: """
        INSERT INTO search_documents_fts(
            rowid, title, description, calendar, tags, projectPath, transcript
        ) VALUES(?, ?, ?, ?, ?, ?, ?)
        """,
        arguments: [
            rowID,
            fields.title,
            fields.description,
            fields.calendar,
            fields.tags,
            fields.projectPath,
            fields.transcript,
        ]
    )
}

private func updateFTS(rowID: Int64, fields: SearchDocumentFields, in db: Database) throws {
    try db.execute(
        sql: """
        UPDATE search_documents_fts
        SET title = ?, description = ?, calendar = ?, tags = ?, projectPath = ?, transcript = ?
        WHERE rowid = ?
        """,
        arguments: [
            fields.title,
            fields.description,
            fields.calendar,
            fields.tags,
            fields.projectPath,
            fields.transcript,
            rowID,
        ]
    )
}
