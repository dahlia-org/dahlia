import Foundation
import GRDB

enum MeetingEventRecorder {
    enum Kind: String, Encodable {
        case tagAdded = "tag_added"
        case tagRemoved = "tag_removed"
        case recordingStarted = "recording_started"
        case recordingEnded = "recording_ended"
        case segmentRotated = "segment_rotated"
    }

    private struct Payload: Encodable {
        let meetingId: String
        let kind: Kind
        let occurredAt: Date
        let sessionId: String?
        let relatedId: String?
        let audioSource: String?
        let segmentIndex: Int?
    }

    static func recordStarted(sessionId: UUID, dbQueue: DatabaseQueue) async {
        do {
            try await dbQueue.write { db in
                guard let session = try RecordingSessionRecord.fetchOne(db, key: sessionId) else { return }
                try record(.recordingStarted, meetingId: session.meetingId, at: session.startedAt, sessionId: session.id, in: db)
            }
        } catch {
            ErrorReportingService.capture(error, context: ["source": "recordingEvent"])
        }
    }

    static func record(
        _ kind: Kind,
        meetingId: UUID,
        at occurredAt: Date = .now,
        sessionId: UUID? = nil,
        relatedId: String? = nil,
        audioSource: RecordingAudioSource? = nil,
        segmentIndex: Int? = nil,
        in db: Database
    ) throws {
        guard let meeting = try MeetingRecord.fetchOne(db, key: meetingId),
              let vault = try VaultRecord.fetchOne(db, key: meeting.vaultId),
              try Int.fetchOne(db, sql: "SELECT syncMeetingEventsVersion FROM vaults WHERE id = ?", arguments: [vault.id]) == 1,
              vault.accountConnectionId != nil,
              vault.accountConnectionId == vault.syncConfirmedConnectionId,
              vault.syncRole != "member" else { return }
        let payload = Payload(
            meetingId: meetingId.uuidString.lowercased(), kind: kind, occurredAt: occurredAt,
            sessionId: sessionId?.uuidString.lowercased(), relatedId: relatedId,
            audioSource: audioSource?.audioSource, segmentIndex: segmentIndex
        )
        try SyncTransactionRecorder.record(
            vaultId: meeting.vaultId,
            operations: [SyncOperationDraft(entity: .meetingEvent, action: .create, entityId: .v7(), payloadJSON: SyncJSON.encoder.encode(payload))],
            in: db
        )
    }
}
