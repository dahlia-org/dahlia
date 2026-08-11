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
