import Foundation

public struct MeetingQuery: Sendable, Equatable {
    public var query: String?
    public var project: String?
    public var createdFrom: Date?
    public var createdBefore: Date?
    public var limit: Int
    public var cursor: String?

    public init(
        query: String? = nil,
        project: String? = nil,
        createdFrom: Date? = nil,
        createdBefore: Date? = nil,
        limit: Int = 25,
        cursor: String? = nil
    ) {
        self.query = query
        self.project = project
        self.createdFrom = createdFrom
        self.createdBefore = createdBefore
        self.limit = limit
        self.cursor = cursor
    }
}

public struct MeetingQueryPage: Codable, Sendable, Equatable {
    public let vault: ScopedVault
    public let meetings: [MeetingMetadata]
    public let nextCursor: String?
}

public struct ScopedVault: Codable, Sendable, Equatable {
    public let id: UUID
    public let name: String
}

public struct MeetingMetadata: Codable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let description: String
    public let project: String?
    public let calendarTitle: String?
    public let status: String
    public let durationSeconds: Double?
    public let createdAt: Date
    public let hasSummary: Bool
    public let transcriptSegmentCount: Int
    public let tags: [String]
}

public struct MeetingDetail: Codable, Sendable, Equatable {
    public let vault: ScopedVault
    public let meeting: MeetingMetadata
    public let summary: String?
}

public struct TranscriptPage: Codable, Sendable, Equatable {
    public let vault: ScopedVault
    public let meetingID: UUID
    public let segments: [TranscriptEntry]
    public let nextCursor: String?
}

public struct TranscriptEntry: Codable, Sendable, Equatable {
    public let id: UUID
    public let text: String
    public let speaker: String?
    public let startedAt: Date
    public let endedAt: Date?
    public let elapsedSeconds: Double
}

public enum MeetingAccessError: Error, LocalizedError, Equatable {
    case vaultNotFound
    case meetingNotFound
    case databaseUpgradeRequired
    case invalidSummaryDocument
    case invalidCursor
    case invalidLimit(maximum: Int)

    public var errorDescription: String? {
        switch self {
        case .vaultNotFound:
            "The configured vault was not found."
        case .meetingNotFound:
            "The meeting was not found in the configured vault."
        case .databaseUpgradeRequired:
            "The Dahlia database must be upgraded before meeting access can start. Open Dahlia once, then try again."
        case .invalidSummaryDocument:
            "The stored summary document is invalid. Open Dahlia and regenerate the summary."
        case .invalidCursor:
            "The cursor is invalid for the configured vault or meeting."
        case let .invalidLimit(maximum):
            "The limit must be between 1 and \(maximum)."
        }
    }
}
