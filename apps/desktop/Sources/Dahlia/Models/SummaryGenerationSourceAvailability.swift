import Foundation
import GRDB

struct SummaryGenerationSourceAvailability: Equatable, Sendable {
    let meetingCount: Int
    let transcriptCount: Int
    let audioCount: Int
    let supportedSources: Set<SummaryGenerationSource>
    let usesServer: Bool

    func isAvailable(_ source: SummaryGenerationSource) -> Bool {
        supportedSources.contains(source) && availableCount(for: source) == meetingCount
    }

    func availableCount(for source: SummaryGenerationSource) -> Int {
        switch source {
        case .transcript: transcriptCount
        case .audio: audioCount
        }
    }

    var preferredSource: SummaryGenerationSource? {
        if isAvailable(.transcript) { return .transcript }
        if isAvailable(.audio) { return .audio }
        return nil
    }
}

extension SummaryGenerationSourceAvailability {
    static func load(
        meetingIDs: Set<UUID>,
        supportedSources: Set<SummaryGenerationSource>,
        usesServer: Bool,
        serverTranscriptMeetingIDs: Set<UUID> = [],
        serverAudioMeetingIDs: Set<UUID> = [],
        dbQueue: DatabaseQueue
    ) async throws -> Self {
        try await dbQueue.read { db in
            var transcriptCount = 0
            var audioCount = 0

            for meetingID in meetingIDs {
                let hasTranscript = usesServer
                    ? serverTranscriptMeetingIDs.contains(meetingID)
                    : try hasTranscript(meetingID: meetingID, in: db)
                if hasTranscript { transcriptCount += 1 }

                let hasAudio = if usesServer {
                    if serverAudioMeetingIDs.contains(meetingID) {
                        try hasNoPendingServerAudio(meetingID: meetingID, in: db)
                    } else {
                        false
                    }
                } else {
                    try Self.hasAudio(meetingID: meetingID, in: db)
                }
                if hasAudio {
                    audioCount += 1
                }
            }

            return Self(
                meetingCount: meetingIDs.count,
                transcriptCount: transcriptCount,
                audioCount: audioCount,
                supportedSources: supportedSources,
                usesServer: usesServer
            )
        }
    }

    static func hasTranscript(
        meetingID: UUID,
        in db: Database
    ) throws -> Bool {
        let texts = try String.fetchCursor(
            db,
            sql: """
            SELECT b.text
            FROM transcript_segments s
            JOIN transcript_segment_bodies b ON b.segmentId = s.id
            WHERE s.meetingId = ?
            """,
            arguments: [meetingID]
        )
        while let text = try texts.next() {
            if text.nilIfBlank != nil { return true }
        }
        return false
    }

    static func hasNoPendingServerAudio(meetingID: UUID, in db: Database) throws -> Bool {
        let sessions = try RecordingSessionRecord.filter(Column("meetingId") == meetingID).fetchAll(db)
        return try sessions.allSatisfy {
            guard $0.transcriptionMode == .batch, $0.batchDiscardedAt == nil, $0.endedAt != nil else { return false }
            return try RecordingArchiveRecord.isAvailable(sessionId: $0.id, in: db)
        }
    }

    static func hasAudio(meetingID: UUID, in db: Database) throws -> Bool {
        let sessions = try RecordingSessionRecord
            .filter(Column("meetingId") == meetingID)
            .filter(Column("transcriptionMode") == "batch" && Column("batchDiscardedAt") == nil)
            .fetchAll(db)
        guard !sessions.isEmpty else { return false }
        return try sessions.allSatisfy {
            guard $0.endedAt != nil else { return false }
            return try RecordingArchiveRecord.isAvailable(sessionId: $0.id, in: db)
        }
    }
}
