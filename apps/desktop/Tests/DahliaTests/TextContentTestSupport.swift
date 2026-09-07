#if canImport(Testing)
    import DahliaMeetingAccess
    import Foundation
    import GRDB
    @testable import Dahlia

    func fetchTranscriptContent(id: UUID, in db: Database) throws -> TranscriptContent? {
        guard let metadata = try TranscriptSegmentRecord.fetchOne(db, key: id) else { return nil }
        return try TextContentAccess.transcript(
            meetingId: metadata.meetingId, order: .id,
            position: .init(id: id, startTime: metadata.startTime), inclusive: true, limit: 1, in: db
        ).first
    }

    func fetchSessionTranscriptContent(sessionId: UUID, in db: Database) throws -> [TranscriptContent] {
        guard let session = try RecordingSessionRecord.fetchOne(db, key: sessionId) else { return [] }
        return try TextContentAccess.transcript(meetingId: session.meetingId, in: db).filter { $0.sessionId == sessionId }
    }
#endif
