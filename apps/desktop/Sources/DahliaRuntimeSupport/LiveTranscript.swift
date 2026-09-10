import CryptoKit
import Foundation

/// Live previews are replaceable projections. Confirmed speech is read from durable transcript storage.
public struct LiveSpeech: Codable, Equatable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let endedAt: Date?
    public let text: String
    public let audioSource: String?
    public let speakerLabel: String?

    public init(id: UUID, startedAt: Date, endedAt: Date?, text: String, audioSource: String?, speakerLabel: String?) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.text = text
        self.audioSource = audioSource
        self.speakerLabel = speakerLabel
    }
}

public struct LiveTranscriptState: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case recording, disabled, stopped, failed, disconnected }
    public let vaultId: UUID
    public let meetingId: UUID
    public let sessionId: UUID
    public let startedAt: Date
    public var status: Status
    public var sequence: Int
    public var updatedAt: Date
    public var previews: [LiveSpeech]

    public init(vaultId: UUID, meetingId: UUID, sessionId: UUID, startedAt: Date, enabled: Bool) {
        self.vaultId = vaultId
        self.meetingId = meetingId
        self.sessionId = sessionId
        self.startedAt = startedAt
        status = enabled ? .recording : .disabled
        sequence = 0
        updatedAt = startedAt
        previews = []
    }
}

public struct LiveTranscriptPage: Codable, Sendable {
    public let state: LiveTranscriptState
    public let confirmed: [LiveSpeech]
    public let cursor: String
    public let hasMore: Bool
    public let resetRequired: Bool

    private struct Cursor: Codable {
        let vaultId: UUID
        let meetingId: UUID
        let sessionId: UUID
        let generation: String
        let position: Int
        let digest: String
    }

    /// ponytail: O(n) prefix verification catches edits/deletions/late inserts; use a durable change journal if long-meeting reads become costly.
    public static func read(state: LiveTranscriptState, generation: String, segments: [LiveSpeech], cursor: String?, limit: Int) throws -> Self {
        guard (1 ... 500).contains(limit) else { throw LiveTranscriptError.invalidRequest }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        func digest(_ count: Int) throws -> String {
            try SHA256.hash(data: encoder.encode(Array(segments.prefix(count)))).map { String(format: "%02x", $0) }.joined()
        }
        var position = 0
        var reset = false
        if let cursor {
            guard cursor.utf8.count <= 2048, let bytes = Data(base64Encoded: cursor),
                  let previous = try? JSONDecoder().decode(Cursor.self, from: bytes),
                  previous.vaultId == state.vaultId, previous.meetingId == state.meetingId,
                  previous.position >= 0 else { throw LiveTranscriptError.invalidCursor }
            if previous.sessionId != state.sessionId || previous.generation != generation || previous.position > segments.count {
                reset = true
            } else if try previous.digest != digest(previous.position) {
                reset = true
            } else { position = previous.position }
        }
        let end = min(segments.count, position + limit)
        let next = try Cursor(
            vaultId: state.vaultId,
            meetingId: state.meetingId,
            sessionId: state.sessionId,
            generation: generation,
            position: end,
            digest: digest(end)
        )
        return try Self(
            state: state,
            confirmed: Array(segments[position ..< end]),
            cursor: encoder.encode(next).base64EncodedString(),
            hasMore: end < segments.count,
            resetRequired: reset
        )
    }
}

public enum LiveTranscriptError: String, Error, Codable, Sendable {
    case invalidRequest = "invalid_live_request"
    case invalidCursor = "invalid_live_cursor"
    case appUnavailable = "app_unavailable"
    case notFound = "live_meeting_not_found"
}
