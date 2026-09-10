import DahliaMeetingAccess
import DahliaRuntimeSupport
import Foundation
import GRDB
import Synchronization

/// Only bounded preview state crosses the recognition path. Disk and network readers run independently.
final class LiveTranscriptStore: Sendable {
    static let shared = LiveTranscriptStore()
    private struct Key: Hashable { let database: ObjectIdentifier
        let meetingID: UUID
    }

    private let states = Mutex<[Key: LiveTranscriptState]>([:])

    func begin(_ state: LiveTranscriptState, database: DatabaseQueue) {
        states.withLock { values in
            values = values.filter { ![.stopped, .failed].contains($0.value.status) || $0.value.updatedAt > Date().addingTimeInterval(-45) }
            values[Key(database: ObjectIdentifier(database), meetingID: state.meetingId)] = state
        }
    }

    func observe(_ event: TranscriptionEvent, meetingID: UUID, database: DatabaseQueue) {
        states.withLock { values in
            let key = Key(database: ObjectIdentifier(database), meetingID: meetingID)
            guard var state = values[key], state.status == .recording else { return }
            switch event {
            case let .preview(segment), let .finalized(segment):
                guard segment.sessionId == state.sessionId else { return }
                state.previews.removeAll { $0.audioSource == segment.audioSource }
                if !segment.isConfirmed, !segment.text.isEmpty {
                    // Bound local preview payloads in UTF-16 units while retaining whole characters; confirmed text is never truncated.
                    var remainingUTF16 = 16000
                    let preview = segment.text.prefix {
                        remainingUTF16 -= String($0).utf16.count
                        return remainingUTF16 >= 0
                    }
                    state.previews.append(LiveSpeech(
                        id: segment.id,
                        startedAt: segment.startTime,
                        endedAt: segment.endTime,
                        text: String(preview),
                        audioSource: segment.audioSource,
                        speakerLabel: segment.speakerLabel
                    ))
                    state.previews = Array(state.previews.suffix(8))
                }
            case let .clearPreview(sessionID, source):
                guard sessionID == state.sessionId else { return }
                state.previews.removeAll { $0.audioSource == source }
            case let .failure(sessionID, _, source, _):
                guard sessionID == state.sessionId else { return }
                // A recognizer can fail while recording and other sources continue; finish owns terminal status.
                state.previews.removeAll { $0.audioSource == source }
            case .translation, .previewTranslation: return
            }
            state.sequence += 1
            state.updatedAt = .now
            values[key] = state
        }
    }

    func finish(meetingID: UUID, database: DatabaseQueue, failed: Bool = false) {
        states.withLock { values in
            let key = Key(database: ObjectIdentifier(database), meetingID: meetingID)
            guard var state = values[key] else { return }
            state.status = failed ? .failed : .stopped
            state.previews = []
            state.sequence += 1
            state.updatedAt = .now
            values[key] = state
        }
    }

    func snapshot(meetingID: UUID, database: DatabaseQueue) -> LiveTranscriptState? {
        states.withLock { $0[Key(database: ObjectIdentifier(database), meetingID: meetingID)] }
    }

    func list(vaultID: UUID, database: DatabaseQueue) -> [LiveTranscriptState] {
        states.withLock { values in
            values.filter { $0.key.database == ObjectIdentifier(database) && $0.value.vaultId == vaultID
                &&
                ($0.value.status == .recording || $0.value
                    .status == .disabled || ($0.value.status == .failed && $0.value.updatedAt > Date().addingTimeInterval(-45)))
            }.map(\.value).sorted { $0.startedAt < $1.startedAt }
        }
    }

    func read(vaultID: UUID, meetingID: UUID, cursor: String?, limit: Int, database: DatabaseQueue) async throws -> LiveTranscriptPage {
        let live = snapshot(meetingID: meetingID, database: database)
        return try await database.read { db in
            guard let meeting = try MeetingRecord.fetchOne(db, key: meetingID), meeting.vaultId == vaultID else { throw LiveTranscriptError.notFound }
            var sessions = RecordingSessionRecord.filter(Column("meetingId") == meetingID)
            if let live { sessions = sessions.filter(Column("id") == live.sessionId) }
            let session = try sessions.order(Column("startedAt").desc).fetchOne(db)
            guard let session else { throw LiveTranscriptError.notFound }
            var state = live ?? LiveTranscriptState(
                vaultId: vaultID,
                meetingId: meetingID,
                sessionId: session.id,
                startedAt: session.startedAt,
                enabled: false
            )
            if live == nil { state.status = session.endedAt == nil ? .disconnected : .stopped }
            guard state.vaultId == vaultID else { throw LiveTranscriptError.notFound }
            try TextContentAccess.requireComplete(entity: .transcript, id: meetingID, in: db)
            let transcript = try TranscriptRecord.current(meetingID, in: db)
            // Canonical downloads have no segment session ID; their timestamps retain the recording timeline.
            let rows = try Row.fetchAll(db, sql: """
            SELECT s.id, s.startedAt, s.endedAt, b.text, s.audioSource, s.speakerLabel
            FROM transcript_segments s JOIN transcript_segment_bodies b ON b.segmentId = s.id
            WHERE s.meetingId = ? AND (
                s.sessionId = ? OR (
                    s.sessionId IS NULL AND s.startedAt >= ? AND (? IS NULL OR s.startedAt <= ?)
                )
            ) ORDER BY s.createdAt, s.id
            """, arguments: [meetingID, state.sessionId, session.startedAt, session.endedAt, session.endedAt])
            let segments = rows.map { row in
                LiveSpeech(
                    id: row["id"],
                    startedAt: row["startedAt"],
                    endedAt: row["endedAt"],
                    text: row["text"],
                    audioSource: row["audioSource"],
                    speakerLabel: row["speakerLabel"]
                )
            }
            return try LiveTranscriptPage.read(
                state: state,
                generation: transcript?.id.uuidString.lowercased() ?? "none",
                segments: segments,
                cursor: cursor,
                limit: limit
            )
        }
    }
}
