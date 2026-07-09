import Foundation

struct SummaryRenderContext {
    let meetingId: UUID
    let createdAt: Date
    let screenshots: [MeetingScreenshotRecord]

    init(meetingId: UUID, createdAt: Date, screenshots: [MeetingScreenshotRecord] = []) {
        self.meetingId = meetingId
        self.createdAt = createdAt
        self.screenshots = screenshots
    }
}
