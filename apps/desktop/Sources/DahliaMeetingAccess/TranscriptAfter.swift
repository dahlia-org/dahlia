import CryptoKit
import Foundation

public enum TranscriptAfterError: String, Error {
    case invalid = "invalid_transcript_after"
    case changed = "transcript_changed_refetch_without_after"
}

struct TranscriptAfter: Codable {
    let vaultID: UUID
    let meetingID: UUID
    let from: Double?
    let to: Double?
    let generation: String
    let position: Int
    let digest: String

    // ponytail: O(n) prefix verification detects edits/deletions/late inserts; use a change journal if long-meeting reads become costly.
    static func page(
        vaultID: UUID,
        meetingID: UUID,
        from: Double?,
        to: Double?,
        generation: String,
        segments: [TranscriptEntry],
        after: String?,
        start: Int,
        limit: Int
    ) throws -> (segments: [TranscriptEntry], next: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func digest(_ count: Int) throws -> String {
            try SHA256.hash(data: encoder.encode(Array(segments.prefix(count)))).map { String(format: "%02x", $0) }.joined()
        }
        var position = start
        if let after {
            guard after.utf8.count <= 2048, let bytes = Data(base64Encoded: after),
                  let previous = try? JSONDecoder().decode(Self.self, from: bytes), previous.position >= 0,
                  previous.vaultID == vaultID, previous.meetingID == meetingID, previous.from == from, previous.to == to else {
                throw TranscriptAfterError.invalid
            }
            guard previous.generation == generation || previous.generation == "none", previous.position <= segments.count,
                  try previous.digest == digest(previous.position) else { throw TranscriptAfterError.changed }
            position = previous.position
        }
        let end = min(segments.count, position + limit)
        let next = try Self(vaultID: vaultID, meetingID: meetingID, from: from, to: to, generation: generation, position: end, digest: digest(end))
        return try (Array(segments[position ..< end]), encoder.encode(next).base64EncodedString())
    }
}
