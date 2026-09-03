import CryptoKit
import Foundation

struct MeetingConversationMetricsInput: Codable, Equatable, Sendable {
    struct Session: Codable, Equatable, Sendable {
        let id: UUID
        let startedAt: Date
        let duration: TimeInterval?
        let offsetSeconds: TimeInterval
    }

    struct Segment: Codable, Equatable, Sendable {
        let id: UUID
        let sessionId: UUID?
        let startTime: Date
        let endTime: Date?
        let text: String
        let audioSource: String
        var audioFeatures: TranscriptAudioFeatures?

        private enum CodingKeys: String, CodingKey {
            case id
            case sessionId
            case startTime
            case endTime
            case text
            case audioSource
        }

        init(
            id: UUID,
            sessionId: UUID?,
            startTime: Date,
            endTime: Date?,
            text: String,
            audioSource: String,
            audioFeatures: TranscriptAudioFeatures? = nil
        ) {
            self.id = id
            self.sessionId = sessionId
            self.startTime = startTime
            self.endTime = endTime
            self.text = text
            self.audioSource = audioSource
            self.audioFeatures = audioFeatures
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            sessionId = try container.decodeIfPresent(UUID.self, forKey: .sessionId)
            startTime = try container.decode(Date.self, forKey: .startTime)
            endTime = try container.decodeIfPresent(Date.self, forKey: .endTime)
            text = try container.decode(String.self, forKey: .text)
            audioSource = try container.decode(String.self, forKey: .audioSource)
            audioFeatures = nil
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(sessionId, forKey: .sessionId)
            try container.encode(startTime, forKey: .startTime)
            try container.encodeIfPresent(endTime, forKey: .endTime)
            try container.encode(text, forKey: .text)
            try container.encode(audioSource, forKey: .audioSource)
        }
    }

    let meetingDuration: TimeInterval?
    let sessions: [Session]
    let segments: [Segment]

    init(
        meetingDuration: TimeInterval?,
        sessions: [Session],
        segments: [Segment]
    ) {
        self.meetingDuration = meetingDuration
        self.sessions = sessions.sorted {
            if $0.offsetSeconds == $1.offsetSeconds {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.offsetSeconds < $1.offsetSeconds
        }
        self.segments = segments.sorted {
            if $0.startTime == $1.startTime {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.startTime < $1.startTime
        }
    }

    func fingerprint() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(self)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
