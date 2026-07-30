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
        let speakerLabel: String
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
