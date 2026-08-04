import Foundation

struct TranscriptPageCursor: Equatable {
    let startTime: Date
    let id: UUID

    init(segment: TranscriptSegment) {
        self.startTime = segment.startTime
        self.id = segment.id
    }
}

enum TranscriptPageDirection: Equatable {
    case latest
    case before(TranscriptPageCursor)
    case after(TranscriptPageCursor)
}

struct TranscriptPage: Equatable {
    let segments: [TranscriptSegment]
    let hasEarlier: Bool
    let hasLater: Bool
}

struct TranscriptReferencePage: Equatable {
    let targetSegmentID: UUID
    let page: TranscriptPage
}

enum TranscriptReferenceTime {
    static func seconds(from value: String) -> TimeInterval? {
        let components = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard components.count == 3,
              let hours = Int(components[0]),
              let minutes = Int(components[1]),
              let seconds = Int(components[2]),
              hours >= 0,
              (0 ..< 60).contains(minutes),
              (0 ..< 60).contains(seconds) else { return nil }
        return TimeInterval(hours) * 3600 + TimeInterval(minutes * 60 + seconds)
    }
}
