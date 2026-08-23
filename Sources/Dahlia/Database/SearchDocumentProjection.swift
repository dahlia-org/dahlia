import CryptoKit
import Foundation
import GRDB

struct SearchDocumentProjection {
    let kind: String
    let sourceID: UUID
    let vaultID: UUID
    let meetingID: UUID?
    let projectID: UUID?
    let fields: SearchDocumentFields
}

struct SearchDocumentFields {
    let title: String
    let description: String
    let summary: String
    let calendar: String
    let tags: String
    let projectPath: String
    let ocr: String
    let caption: String
    let summaryDescription: String

    init(
        title: String,
        description: String,
        summary: String = "",
        calendar: String,
        tags: String,
        projectPath: String,
        ocr: String = "",
        caption: String = "",
        summaryDescription: String = ""
    ) {
        self.title = title
        self.description = description
        self.summary = summary
        self.calendar = calendar
        self.tags = tags
        self.projectPath = projectPath
        self.ocr = ocr
        self.caption = caption
        self.summaryDescription = summaryDescription
    }

    func vectorHash(for kind: String) -> String {
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let content = switch kind {
        case "meeting":
            [trim(title), [summaryDescription, summary].map(trim).filter { !$0.isEmpty }.joined(separator: "\n")]
        case "project":
            [projectPath, trim(description)]
        default:
            [title, description, summary, calendar, tags, projectPath, ocr, caption, summaryDescription]
        }
        let serialized = content
            .map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(serialized.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

func upsertDocument(
    _ document: SearchDocumentProjection,
    generation: Int,
    in db: Database
) throws {
    let hash = document.fields.vectorHash(for: document.kind)
    if let existing = try Row.fetchOne(
        db,
        sql: """
        SELECT id, EXISTS(
            SELECT 1 FROM search_documents_fts WHERE rowid = search_documents.id
        ) AS hasFTS
        FROM search_documents WHERE kind = ? AND sourceId = ?
        """,
        arguments: [document.kind, document.sourceID]
    ) {
        let id: Int64 = existing["id"]
        let hasFTS: Bool = existing["hasFTS"]
        try updateRegistry(document, rowID: id, hash: hash, generation: generation, in: db)
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
            sourceContentHash = ?, indexGeneration = ?, updatedAt = ?
        WHERE id = ?
        """,
        arguments: [
            document.vaultID,
            document.meetingID,
            document.projectID,
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
            sourceContentHash, indexGeneration, updatedAt
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
        """,
        arguments: [
            document.kind,
            document.sourceID,
            document.vaultID,
            document.meetingID,
            document.projectID,
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
            rowid, title, description, summary, calendar, tags, projectPath, ocr, caption
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        arguments: [
            rowID,
            fields.title,
            fields.description,
            fields.summary,
            fields.calendar,
            fields.tags,
            fields.projectPath,
            fields.ocr,
            fields.caption,
        ]
    )
}

private func updateFTS(rowID: Int64, fields: SearchDocumentFields, in db: Database) throws {
    try db.execute(
        sql: """
        UPDATE search_documents_fts
        SET title = ?, description = ?, summary = ?, calendar = ?, tags = ?, projectPath = ?, ocr = ?, caption = ?
        WHERE rowid = ?
        """,
        arguments: [
            fields.title,
            fields.description,
            fields.summary,
            fields.calendar,
            fields.tags,
            fields.projectPath,
            fields.ocr,
            fields.caption,
            rowID,
        ]
    )
}
