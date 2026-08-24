import Foundation

struct ScreenshotSearchMatch: Equatable, Sendable {
    enum Source: Equatable, Hashable, Sendable {
        case ocr
        case caption

        var localizedTitle: String {
            switch self {
            case .ocr:
                L10n.detectedText
            case .caption:
                L10n.imageDescription
            }
        }
    }

    let source: Source
    let snippet: String
}

struct ScreenshotSearchResult: Identifiable, Equatable, Sendable {
    let id: UUID
    let meetingID: UUID
    let meetingTitle: String
    let meetingDescription: String
    let capturedAt: Date
    let mimeType: String
    let matches: [ScreenshotSearchMatch]
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
