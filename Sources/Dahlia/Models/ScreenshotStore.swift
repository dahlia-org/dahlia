import Combine
import Foundation

/// SQLite のスクリーンショット正本を、現在表示中の meeting に限定して公開する UI projection。
@MainActor
final class ScreenshotStore: ObservableObject {
    @Published private(set) var records: [MeetingScreenshotRecord] = []
    private(set) var meetingID: UUID?

    func replace(meetingID: UUID, records: [MeetingScreenshotRecord]) {
        self.meetingID = meetingID
        self.records = records
    }

    func clear() {
        meetingID = nil
        records.removeAll()
    }

    func upsert(_ record: MeetingScreenshotRecord) {
        guard meetingID == record.meetingId else { return }
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
            return
        }
        let insertIndex = records.firstIndex { $0.capturedAt > record.capturedAt } ?? records.endIndex
        records.insert(record, at: insertIndex)
    }

    func remove(ids: Set<UUID>, meetingID: UUID) {
        guard self.meetingID == meetingID else { return }
        records.removeAll { ids.contains($0.id) }
    }
}
