import Combine
import Foundation

/// SQLite のスクリーンショット正本を、現在表示中の meeting に限定して公開する UI projection。
@MainActor
final class ScreenshotStore: ObservableObject {
    @Published private(set) var records: [MeetingScreenshotRecord] = []
    private(set) var meetingID: UUID?
    private(set) var contentRevision: UInt64 = 0
    private var recordRevisions: [UUID: UInt64] = [:]

    func replace(meetingID: UUID, records: [MeetingScreenshotRecord]) {
        self.meetingID = meetingID
        contentRevision &+= 1
        recordRevisions = Dictionary(uniqueKeysWithValues: records.map { ($0.id, contentRevision) })
        self.records = records
    }

    func clear() {
        guard meetingID != nil || !records.isEmpty else { return }
        meetingID = nil
        contentRevision &+= 1
        recordRevisions.removeAll()
        records.removeAll()
    }

    func upsert(_ record: MeetingScreenshotRecord) {
        guard meetingID == record.meetingId else { return }
        contentRevision &+= 1
        recordRevisions[record.id] = contentRevision
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
            return
        }
        let insertIndex = records.firstIndex { $0.capturedAt > record.capturedAt } ?? records.endIndex
        records.insert(record, at: insertIndex)
    }

    func remove(ids: Set<UUID>, meetingID: UUID) {
        guard self.meetingID == meetingID,
              records.contains(where: { ids.contains($0.id) }) else { return }
        contentRevision &+= 1
        for id in ids {
            recordRevisions[id] = nil
        }
        records.removeAll { ids.contains($0.id) }
    }

    func contentRevision(for screenshotID: UUID) -> UInt64? {
        recordRevisions[screenshotID]
    }
}
