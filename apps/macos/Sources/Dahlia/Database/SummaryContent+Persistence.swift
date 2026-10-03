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

    /// Install remote content and its local derived tags without recording sync events.
    func saveCanonical(_ db: Database, applyTags: Bool = true, invalidateExports: Bool = false) throws {
        let previousDocument = try SummaryBodyRecord.fetchOne(db, key: meetingId)?.document
        let changed = previousDocument != document
        try save(db)
        if changed, invalidateExports || previousDocument != nil {
            try SummaryExportRecord.filter(Column("meetingId") == meetingId).deleteAll(db)
        }
        if applyTags, changed, let document = try? loadDocument() {
            try MeetingRepository.mergeGeneratedSummaryTags(document.tags, meetingId: meetingId, recordEvents: false, in: db)
        }
    }

    /// The caller owns the transaction that also records the sync operation.
    func save(_ db: Database) throws {
        try SummaryRecord(meetingId: meetingId, title: title, createdAt: createdAt).save(db)
        try SummaryBodyRecord(meetingId: meetingId, document: document).save(db)
    }
}
