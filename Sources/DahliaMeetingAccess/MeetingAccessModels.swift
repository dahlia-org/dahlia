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

public enum ProjectWorkspaceType: String, Codable, CaseIterable, Sendable {
    case customer
    case `internal`
    case personal
    case undefined
}

public struct ProjectQuery: Sendable, Equatable {
    public var query: String?
    public var projectID: UUID?
    public var type: ProjectWorkspaceType?

    public init(query: String? = nil, projectID: UUID? = nil, type: ProjectWorkspaceType? = nil) {
        self.query = query
        self.projectID = projectID
        self.type = type
    }
}

public struct ProjectMetadata: Codable, Sendable, Equatable {
    public let projectID: UUID
    public let displayName: String
    public let path: String
    public let parentProjectID: UUID?
    public let rootProjectID: UUID
    public let explicitType: ProjectWorkspaceType?
    public let effectiveType: ProjectWorkspaceType
    public let typeOwnerProjectID: UUID
    public let isTypeInherited: Bool
    public let directMeetingCount: Int
    public let descendantMeetingCount: Int
    public let directoryMissing: Bool
    public let description: String
    public let revision: Int
}

public struct ProjectQueryResult: Codable, Sendable, Equatable {
    public let vault: ScopedVault
    public let projects: [ProjectMetadata]
}

public enum ProjectParentUpdate: Sendable, Equatable {
    case unchanged
    case vaultRoot
    case project(UUID)
}

public struct ProjectUpdate: Sendable, Equatable {
    public var leafName: String?
    public var parent: ProjectParentUpdate
    public var description: String?
    public var projectType: ProjectWorkspaceType?
    public var expectedRevision: Int

    public init(
        leafName: String? = nil,
        parent: ProjectParentUpdate = .unchanged,
        description: String? = nil,
        projectType: ProjectWorkspaceType? = nil,
        expectedRevision: Int
    ) {
        self.leafName = leafName
        self.parent = parent
        self.description = description
        self.projectType = projectType
        self.expectedRevision = expectedRevision
    }
}

public struct ProjectMutationResult: Codable, Sendable, Equatable {
    public let project: ProjectMetadata
    public let changed: Bool
    public let affectedProjectIDs: [UUID]
    public let effectiveTypeChangedProjectIDs: [UUID]
}

public struct MeetingProjectMembershipExpectation: Sendable, Equatable {
    public let meetingID: UUID
    public let expectedProjectID: UUID?

    public init(meetingID: UUID, expectedProjectID: UUID?) {
        self.meetingID = meetingID
        self.expectedProjectID = expectedProjectID
    }
}

public struct MeetingProjectMembershipResult: Codable, Sendable, Equatable {
    public let changed: Bool
    public let changedMeetingIDs: [UUID]
    public let projectID: UUID?
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
    case writeAccessRequired
    case projectNotFound
    case projectConflict(String)
    case invalidProjectName
    case projectDirectoryMissing
    case projectFileConflict(String)
    case projectTypeOwnedByRoot
    case meetingMembershipConflict
    case workspaceBusy
    case workspaceRollbackFailed

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
        case .writeAccessRequired:
            "This dahlia-mcp process is read-only. Restart it with --write to use update tools."
        case .projectNotFound:
            "The project was not found in the configured vault."
        case let .projectConflict(message):
            "Project update conflict: \(message)"
        case .invalidProjectName:
            "Project leaf_name must be a non-hidden single directory name."
        case .projectDirectoryMissing:
            "The project directory is missing."
        case let .projectFileConflict(path):
            "A directory or file already exists at \(path)."
        case .projectTypeOwnedByRoot:
            "Only a root project can have an explicit project type."
        case .meetingMembershipConflict:
            "At least one meeting no longer has the expected project membership; no meetings were changed."
        case .workspaceBusy:
            "Another Dahlia process is updating this vault. Refresh the project state and try again."
        case .workspaceRollbackFailed:
            "The workspace update failed and its filesystem rollback also failed."
        }
    }
}
