import Combine
import Foundation

/// SQLite のスクリーンショット正本を、現在表示中の meeting に限定して公開する UI projection。
@MainActor
final class ScreenshotStore: ObservableObject {
    @Published private(set) var records: [MeetingScreenshotRecord] = []
    private(set) var meetingID: UUID?
    private(set) var contentRevision: UInt64 = 0

    func replace(meetingID: UUID, records: [MeetingScreenshotRecord]) {
        self.meetingID = meetingID
        contentRevision &+= 1
        self.records = records.map { $0.metadataOnly() }
    }

    func clear() {
        guard meetingID != nil || !records.isEmpty else { return }
        meetingID = nil
        contentRevision &+= 1
        records.removeAll()
    }

    func upsert(_ record: MeetingScreenshotRecord) {
        guard meetingID == record.meetingId else { return }
        contentRevision &+= 1
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record.metadataOnly()
            return
        }
        let insertIndex = records.firstIndex { $0.capturedAt > record.capturedAt } ?? records.endIndex
        records.insert(record.metadataOnly(), at: insertIndex)
    }

    func remove(ids: Set<UUID>, meetingID: UUID) {
        guard self.meetingID == meetingID,
              records.contains(where: { ids.contains($0.id) }) else { return }
        contentRevision &+= 1
        records.removeAll { ids.contains($0.id) }
    }
}
