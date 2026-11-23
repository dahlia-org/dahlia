import DahliaMeetingAccess
import DahliaRuntimeSupport
import Foundation
import GRDB

extension SummaryContent {
    static func fetchOne(_ db: Database, key: UUID) throws -> Self? {
        try TextContentAccess.summary(meetingId: key, in: db)
    }

    func loadDocument() throws -> SummaryDocument {
        try SummaryDocument.decode(databaseJSON: document)
    }

    func insert(_ db: Database) throws {
        try SummaryRecord(meetingId: meetingId, title: title, createdAt: createdAt).insert(db)
        try SummaryBodyRecord(meetingId: meetingId, document: document).insert(db)
    }

    /// The caller owns the transaction that also records the sync operation.
    func save(_ db: Database) throws {
        try SummaryRecord(meetingId: meetingId, title: title, createdAt: createdAt).save(db)
        try SummaryBodyRecord(meetingId: meetingId, document: document).save(db)
    }
}
