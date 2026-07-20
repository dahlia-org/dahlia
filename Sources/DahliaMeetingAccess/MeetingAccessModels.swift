import Foundation

public struct MeetingQuery: Sendable, Equatable {
    public var query: String?
    public var project: String?
    public var projectID: UUID?
    public var icalUID: String?
    public var createdFrom: Date?
    public var createdBefore: Date?
    public var limit: Int
    public var cursor: String?

    public init(
        query: String? = nil,
        project: String? = nil,
        projectID: UUID? = nil,
        icalUID: String? = nil,
        createdFrom: Date? = nil,
        createdBefore: Date? = nil,
        limit: Int = 25,
        cursor: String? = nil
    ) {
        self.query = query
        self.project = project
        self.projectID = projectID
        self.icalUID = icalUID
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
    public let projectID: UUID?
    public let icalUID: String?
    public let recurrenceID: String?
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
    public let summaryDocument: JSONValue?
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
    public let endedElapsedSeconds: Double?
    public let timestamp: String
}

public struct ScreenshotQuery: Sendable, Equatable {
    public var fromElapsedSeconds: Double?
    public var toElapsedSeconds: Double?
    public var limit: Int
    public var cursor: String?

    public init(
        fromElapsedSeconds: Double? = nil,
        toElapsedSeconds: Double? = nil,
        limit: Int = 20,
        cursor: String? = nil
    ) {
        self.fromElapsedSeconds = fromElapsedSeconds
        self.toElapsedSeconds = toElapsedSeconds
        self.limit = limit
        self.cursor = cursor
    }
}

public struct MeetingScreenshotPage: Codable, Sendable, Equatable {
    public let vault: ScopedVault
    public let meetingID: UUID
    public let screenshots: [MeetingScreenshotMetadata]
    public let nextCursor: String?
}

public struct MeetingScreenshotMetadata: Codable, Sendable, Equatable {
    public let id: UUID
    public let capturedAt: Date
    public let elapsedSeconds: Double
    public let timestamp: String
    public let mimeType: String
    public let isReferencedInSummary: Bool
}

public struct MeetingScreenshotImage: Sendable, Equatable {
    public let metadata: MeetingScreenshotMetadata
    public let imageData: Data
    public let mimeType: String
}

public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: Self])
    case array([Self])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode([String: Self].self) {
            self = .object(value)
        } else if let value = try? container.decode([Self].self) {
            self = .array(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = try .string(container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public enum MeetingAccessError: Error, LocalizedError, Equatable {
    case vaultNotFound
    case meetingNotFound
    case databaseUpgradeRequired
    case invalidSummaryDocument
    case invalidCursor
    case invalidLimit(maximum: Int)
    case invalidTimeRange
    case screenshotNotFound
    case screenshotEncodingFailed

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
        case .invalidTimeRange:
            "Elapsed time values must be finite and nonnegative, and the start must be before the end."
        case .screenshotNotFound:
            "The screenshot was not found in the configured meeting and vault."
        case .screenshotEncodingFailed:
            "The screenshot could not be resized for MCP access."
        }
    }
}
