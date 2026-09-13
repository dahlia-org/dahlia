import DahliaRuntimeSupport
import Foundation
import GRDB

/// Shared by the app and the read-only helper. Checking availability never performs network I/O.
public enum TextContentAccess {
    public static func availability(entity: TextContentEntity, id: UUID, in db: Database) throws -> TextContentAvailability {
        guard try db.tableExists("sync_content_state"),
              let row = try Row.fetchOne(db, sql: """
              SELECT c.*, s.confirmedRevision FROM sync_content_state c
              LEFT JOIN sync_entity_state s ON s.workspace_id = c.workspace_id AND s.entity = c.entity AND s.entityId = c.entityId
              WHERE c.entity = ? AND c.entityId = ?
              """, arguments: [entity.rawValue, id]) else { return .init(state: .ready) }
        let resident: Int? = row["residentRevision"]
        let latest: Int? = row["confirmedRevision"]
        let emptyTranscript = if entity == .transcript, row["complete"] as Bool {
            try Bool.fetchOne(
                db,
                sql: "SELECT NOT EXISTS(SELECT 1 FROM transcript_segments WHERE meetingId = ?)",
                arguments: [id]
            ) == true
        } else { false }
        let state: TextContentAvailability.State
        if row["fetchError"] as String? == TextContentError.deleted.rawValue {
            state = .deleted
        } else if !(row["present"] as Bool) || emptyTranscript {
            state = .empty
        } else if !(row["complete"] as Bool) {
            let error: String? = row["fetchError"]
            state = switch error {
            case "loading": .loading
            case nil: .missing
            default: .failed
            }
        } else if latest != nil, resident != latest {
            state = .stale
        } else {
            state = .ready
        }
        return .init(state: state, revision: resident, latestRevision: latest)
    }

    public static func requireComplete(entity: TextContentEntity, id: UUID, in db: Database) throws {
        let state = try availability(entity: entity, id: id, in: db).state
        guard [.ready, .stale, .empty].contains(state) else { throw TextContentError.incomplete }
        let missingBodySQL = switch entity {
        case .transcript:
            "SELECT EXISTS(SELECT 1 FROM transcript_segments t LEFT JOIN transcript_segment_bodies b ON b.segmentId = t.id WHERE t.meetingId = ? AND b.segmentId IS NULL)"
        case .summary:
            "SELECT EXISTS(SELECT 1 FROM summaries s LEFT JOIN summary_bodies b ON b.meetingId = s.meetingId WHERE s.meetingId = ? AND b.meetingId IS NULL)"
        case .file:
            "SELECT EXISTS(SELECT 1 FROM files f LEFT JOIN file_text_bodies b ON b.fileId = f.id WHERE f.id = ? AND b.fileId IS NULL)"
        }
        if try Bool.fetchOne(db, sql: missingBodySQL, arguments: [id]) == true {
            throw TextContentError.incomplete
        }
    }

    public static func summary(meetingId: UUID, in db: Database) throws -> SummaryContent? {
        try requireComplete(entity: .summary, id: meetingId, in: db)
        return try cachedSummary(meetingId: meetingId, in: db)
    }

    /// Metadata/search projections may display a resident summary without claiming current completeness.
    public static func cachedSummary(meetingId: UUID, in db: Database) throws -> SummaryContent? {
        try Row.fetchOne(db, sql: """
        SELECT s.*, b.document FROM summaries s JOIN summary_bodies b ON b.meetingId = s.meetingId
        WHERE s.meetingId = ?
        """, arguments: [meetingId]).map(SummaryContent.init(row:))
    }

    public static func fileText(fileId: UUID, in db: Database) throws -> FileTextContent? {
        try requireComplete(entity: .file, id: fileId, in: db)
        return try cachedFileText(fileId: fileId, in: db)
    }

    public static func cachedFileText(fileId: UUID, in db: Database) throws -> FileTextContent? {
        try Row.fetchOne(db, sql: "SELECT ocrText, caption FROM file_text_bodies WHERE fileId = ?", arguments: [fileId])
            .map { FileTextContent(ocrText: $0["ocrText"], caption: $0["caption"]) }
    }

    public enum TranscriptOrder: Sendable { case chronological, reverse, id, elapsed }

    public struct TranscriptPosition: Sendable {
        public var id: UUID
        public var startTime: Date
        public var elapsedSeconds: Double

        public init(id: UUID, startTime: Date, elapsedSeconds: Double = 0) {
            self.id = id
            self.startTime = startTime
            self.elapsedSeconds = elapsedSeconds
        }
    }

    public static func transcript(
        meetingId: UUID,
        order: TranscriptOrder = .chronological,
        position: TranscriptPosition? = nil,
        inclusive: Bool = false,
        fromElapsedSeconds: Double? = nil,
        toElapsedSeconds: Double? = nil,
        confirmedOnly: Bool = false,
        limit: Int? = nil,
        in db: Database
    ) throws -> [TranscriptContent] {
        try transcriptRows(
            meetingId: meetingId, order: order, position: position, inclusive: inclusive,
            fromElapsedSeconds: fromElapsedSeconds, toElapsedSeconds: toElapsedSeconds,
            confirmedOnly: confirmedOnly, limit: limit, in: db
        ).map(TranscriptContent.init(row:))
    }

    /// The app and helper use one checked read, including bounded and elapsed-time pages.
    static func transcriptRows(
        meetingId: UUID,
        order: TranscriptOrder = .chronological,
        position: TranscriptPosition? = nil,
        inclusive: Bool = false,
        fromElapsedSeconds: Double? = nil,
        toElapsedSeconds: Double? = nil,
        confirmedOnly _: Bool = false,
        limit: Int? = nil,
        in db: Database
    ) throws -> [Row] {
        try requireComplete(entity: .transcript, id: meetingId, in: db)
        var predicates: [String] = []
        var arguments: StatementArguments = [meetingId]
        if let fromElapsedSeconds { predicates.append("elapsedSeconds >= ?")
            arguments += [fromElapsedSeconds]
        }
        if let toElapsedSeconds { predicates.append("elapsedSeconds < ?")
            arguments += [toElapsedSeconds]
        }
        let comparator = order == .reverse ? "<" : ">"
        if let position {
            if order == .id {
                predicates.append("id \(comparator)\(inclusive ? "=" : "") ?")
                arguments += [position.id]
            } else {
                let column = order == .elapsed ? "elapsedSeconds" : "startTime"
                predicates.append("(\(column) \(comparator) ? OR (\(column) = ? AND id \(comparator)\(inclusive ? "=" : "") ?))")
                if order == .elapsed {
                    arguments += [position.elapsedSeconds, position.elapsedSeconds, position.id]
                } else {
                    arguments += [position.startTime, position.startTime, position.id]
                }
            }
        }
        let sort = switch order {
        case .chronological: "startTime, id"
        case .reverse: "startTime DESC, id DESC"
        case .id: "id"
        case .elapsed: "elapsedSeconds, id"
        }
        let filter = predicates.isEmpty ? "" : "WHERE " + predicates.joined(separator: " AND ")
        if let limit { arguments += [max(0, limit)] }
        return try Row.fetchAll(db, sql: """
        WITH candidates AS (
            SELECT t.*, t.startedAt AS startTime, t.endedAt AS endTime, b.text, m.createdAt AS meetingCreatedAt,
                s.startedAt AS sessionStartedAt, s.offsetSeconds AS sessionOffsetSeconds,
                max(0, round(CASE WHEN s.startedAt IS NOT NULL AND s.offsetSeconds IS NOT NULL
                    THEN s.offsetSeconds + (julianday(t.startedAt) - julianday(s.startedAt)) * 86400.0
                    ELSE (julianday(t.startedAt) - julianday(m.createdAt)) * 86400.0 END, 3)) AS elapsedSeconds
            FROM transcript_segments t JOIN transcript_segment_bodies b ON b.segmentId = t.id
            JOIN meetings m ON m.id = t.meetingId
            LEFT JOIN recording_sessions s ON s.id = t.sessionId AND s.meetingId = t.meetingId
            WHERE t.meetingId = ?
        )
        SELECT * FROM candidates \(filter) ORDER BY \(sort) \(limit == nil ? "" : "LIMIT ?")
        """, arguments: arguments)
    }

    public static func transcriptCount(meetingId: UUID, in db: Database) throws -> Int {
        let local = try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM transcript_segments WHERE meetingId = ?",
            arguments: [meetingId]
        ) ?? 0
        guard try db.tableExists("sync_content_state") else { return local }
        let remote = try Int.fetchOne(
            db,
            sql: "SELECT contentCount FROM sync_content_state WHERE entity = 'transcript' AND entityId = ? AND complete = 0",
            arguments: [meetingId]
        ) ?? 0
        return max(local, remote)
    }
}
