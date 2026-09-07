import Foundation

struct ServerSearchResults: Decodable, Sendable {
    struct Hit: Decodable, Sendable {
        let id: UUID
        let kind: String
        let title: String
        let date: Date
        let snippet: String
        let meetingId: UUID?
        let projectId: UUID?
        let projectPath: String?
        let fileId: UUID?
        let meetingCount: Int?
    }

    struct Limited: Decodable, Sendable {
        let meeting: Bool
        let screenshot: Bool
        let project: Bool
        var any: Bool { meeting || screenshot || project }
    }

    let vaultId: UUID
    let meetings: [Hit]
    let screenshots: [Hit]
    let projects: [Hit]
    let limited: Limited
}

struct ServerSearchProjection: Sendable {
    let meetings: [MeetingSidebarItem]
    let screenshots: [ScreenshotSearchResult]
    let projects: [ProjectOverviewItem]
    let pendingMeetings: [MeetingSidebarItem]
    let pendingScreenshots: [ScreenshotSearchResult]
    let limited: Bool
    var pendingProjects: [ProjectOverviewItem] = []
    var pendingUnavailable = false
}
