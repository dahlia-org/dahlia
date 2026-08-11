import Foundation
import GRDB

actor TranscriptPageLoader {
    private let repository: MeetingRepository

    init(dbQueue: DatabaseQueue) {
        self.repository = MeetingRepository(dbQueue: dbQueue)
    }

    func load(
        meetingId: UUID,
        direction: TranscriptPageDirection,
        limit: Int
    ) throws -> TranscriptPage {
        try repository.fetchTranscriptPage(
            forMeetingId: meetingId,
            direction: direction,
            limit: limit
        )
    }
}
