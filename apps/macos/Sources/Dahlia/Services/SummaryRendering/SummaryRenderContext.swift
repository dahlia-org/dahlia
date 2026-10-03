import Foundation

struct SummaryRenderContext {
    let meetingId: UUID
    let createdAt: Date
    let screenshots: [MeetingScreenshotRecord]
    let accountScope: AppAccountScope

    init(
        meetingId: UUID,
        createdAt: Date,
        screenshots: [MeetingScreenshotRecord] = [],
        accountScope: AppAccountScope = .local
    ) {
        self.meetingId = meetingId
        self.createdAt = createdAt
        self.screenshots = screenshots
        self.accountScope = accountScope
    }
}
