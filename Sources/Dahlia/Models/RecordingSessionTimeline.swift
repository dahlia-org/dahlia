import Foundation

/// 表示用の録音セッション情報。
struct RecordingSessionTimeline: Identifiable, Equatable {
    let id: UUID
    let startedAt: Date
    var endedAt: Date?
    var offsetSeconds: TimeInterval
}

extension RecordingSessionTimeline {
    init(from record: RecordingSessionRecord) {
        self.init(
            id: record.id,
            startedAt: record.startedAt,
            endedAt: record.endedAt,
            offsetSeconds: record.offsetSeconds
        )
    }
}
