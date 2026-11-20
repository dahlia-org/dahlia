import Foundation

struct ScreenshotSearchResult: Identifiable, Equatable, Sendable {
    let id: UUID
    let meetingID: UUID
    let meetingTitle: String
    let meetingDescription: String
    let capturedAt: Date
    let mimeType: String
    /// Lets the tile reuse the image cache before fetching. nil for rows without a stored file.
    var contentHash: String?
    let snippet: String
}

struct ScreenshotSearchCursor: Equatable, Sendable {
    let indexRevision: Int
    let offset: Int
}

struct ScreenshotSearchPage: Equatable, Sendable {
    let items: [ScreenshotSearchResult]
    let nextCursor: ScreenshotSearchCursor?
    let replacesResults: Bool
}
